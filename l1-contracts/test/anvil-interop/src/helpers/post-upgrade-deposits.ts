import assert from "assert";
import { ethers } from "ethers";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_RECIPIENT_ADDR,
  ETH_TOKEN_ADDRESS,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  POST_UPGRADE_DEPOSIT_AMOUNT,
  TEST_TOKEN_DECIMALS,
} from "../core/const";
import { getAbi, getCreationBytecode } from "../core/contracts";
import { encodeBridgeBurnData, encodeNtvAssetId, encodeTxDataHash } from "../core/data-encoding";
import type { ChainAddresses, CoreDeployedAddresses } from "../core/types";
import { createProvider } from "../core/utils";
import { depositERC20ToL2, depositETHToL2 } from "./l1-deposit-helper";

function readEvent(
  _receipt: ethers.providers.TransactionReceipt,
  _contract: ethers.Contract,
  _name: string
): ethers.utils.LogDescription {
  const topic = _contract.interface.getEventTopic(_name);
  const logs = _receipt.logs.filter(
    (_log) => _log.address.toLowerCase() === _contract.address.toLowerCase() && _log.topics[0] === topic
  );
  assert.strictEqual(logs.length, 1, `Expected one ${_name} event from ${_contract.address}`);
  return _contract.interface.parseLog(logs[0]);
}

async function verifyPriorityRequest(
  _l1TxHash: string,
  _mailbox: ethers.Contract,
  _center: ethers.Contract,
  _expectedValue: ethers.BigNumberish
): Promise<string> {
  const receipt = await _mailbox.provider.getTransactionReceipt(_l1TxHash);
  assert.strictEqual(receipt.status, 1, "L1 deposit failed");
  const request = readEvent(receipt, _mailbox, "NewPriorityRequest");
  const message = readEvent(receipt, _center, "MessageSent");
  const transactionType = _mailbox.interface
    .getEvent("NewPriorityRequest")
    .inputs.find((_input) => _input.name === "transaction");
  assert(transactionType, "Mailbox event has no canonical transaction tuple");
  const canonicalHash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode([transactionType], [request.args.transaction])
  );
  assert.strictEqual(request.args.txHash, canonicalHash, "Mailbox canonical transaction hash mismatch");
  assert.strictEqual(message.args.sendId, canonicalHash, "Center sendId differs from Mailbox canonical hash");
  assert(request.args.transaction.value.eq(_expectedValue), "Wrong priority-transaction value");
  assert(message.args.value.eq(_expectedValue), "Wrong MessageSent value");
  return canonicalHash;
}

/** Exercises real L1 funding and destination calls using the existing Anvil priority-request relay. */
export async function verifyPostUpgradeDeposits(
  _l1RpcUrl: string,
  _l1Addresses: CoreDeployedAddresses,
  _targets: (ChainAddresses & { rpcUrl: string })[]
): Promise<void> {
  const l1Provider = createProvider(_l1RpcUrl);
  const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
  const bridgehub = new ethers.Contract(_l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Provider);
  const center = new ethers.Contract(await bridgehub.interopCenter(), getAbi("L1InteropCenter"), l1Provider);
  const nullifier = new ethers.Contract(_l1Addresses.l1NullifierProxy, getAbi("L1Nullifier"), l1Provider);
  const factory = new ethers.ContractFactory(
    getAbi("TestnetERC20Token"),
    getCreationBytecode("TestnetERC20Token"),
    wallet
  );
  const token = await factory.deploy("Post-upgrade token", "UPGRADE", TEST_TOKEN_DECIMALS);
  await token.deployed();
  const amount = POST_UPGRADE_DEPOSIT_AMOUNT;
  await (await token.mint(wallet.address, amount.mul(_targets.length))).wait();
  const assetId = encodeNtvAssetId((await l1Provider.getNetwork()).chainId, token.address);
  const transferData = encodeBridgeBurnData(amount, ANVIL_RECIPIENT_ADDR, token.address);
  const expectedDataHash = encodeTxDataHash(wallet.address, assetId, transferData);

  for (const target of _targets) {
    assert.strictEqual(
      await bridgehub.baseToken(target.chainId),
      ETH_TOKEN_ADDRESS,
      "Smoke target must use ETH as base token"
    );
    const l2Provider = createProvider(target.rpcUrl);
    const mailbox = new ethers.Contract(target.diamondProxy, getAbi("MailboxFacet"), l1Provider);
    const params = {
      l1RpcUrl: _l1RpcUrl,
      l2RpcUrl: target.rpcUrl,
      chainId: target.chainId,
      l1Addresses: _l1Addresses,
      amount,
      recipient: ANVIL_RECIPIENT_ADDR,
    };
    const nativeBefore = await l2Provider.getBalance(ANVIL_RECIPIENT_ADDR);
    const direct = await depositETHToL2(params);
    assert(direct.l2TxHash, `No direct-deposit relay on chain ${target.chainId}`);
    await verifyPriorityRequest(direct.l1TxHash, mailbox, center, amount);
    const nativeAfter = await l2Provider.getBalance(ANVIL_RECIPIENT_ADDR);
    assert(nativeAfter.sub(nativeBefore).eq(amount), `Wrong direct-deposit balance on chain ${target.chainId}`);

    const l2Vault = new ethers.Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), l2Provider);
    assert.strictEqual(
      await l2Vault.tokenAddress(assetId),
      ethers.constants.AddressZero,
      "Smoke token already registered"
    );
    const custodyBefore = await token.balanceOf(_l1Addresses.l1NativeTokenVault);
    const senderBefore = await token.balanceOf(wallet.address);
    const indirect = await depositERC20ToL2({ ...params, tokenAddress: token.address });
    assert(indirect.l2TxHash, `No indirect-deposit relay on chain ${target.chainId}`);
    assert.strictEqual(indirect.assetId, assetId, "Wrong deposited asset ID");
    const canonicalHash = await verifyPriorityRequest(indirect.l1TxHash, mailbox, center, ethers.constants.Zero);
    assert.strictEqual(
      await nullifier.depositHappened(target.chainId, canonicalHash),
      expectedDataHash,
      "Indirect deposit was not confirmed under its canonical hash"
    );
    assert(
      (await token.balanceOf(_l1Addresses.l1NativeTokenVault)).sub(custodyBefore).eq(amount),
      "Wrong L1 token custody"
    );
    assert(senderBefore.sub(await token.balanceOf(wallet.address)).eq(amount), "Wrong sender token debit");
    assert(
      (await token.allowance(wallet.address, _l1Addresses.l1NativeTokenVault)).isZero(),
      "NTV allowance not consumed"
    );
    const l2TokenAddress = await l2Vault.tokenAddress(assetId);
    assert.notStrictEqual(l2TokenAddress, ethers.constants.AddressZero, "Destination token not registered");
    const l2Token = new ethers.Contract(l2TokenAddress, getAbi("BridgedStandardERC20"), l2Provider);
    assert(
      (await l2Token.balanceOf(ANVIL_RECIPIENT_ADDR)).eq(amount),
      `Wrong token balance on chain ${target.chainId}`
    );
    console.log(`✅ Post-upgrade direct and indirect deposits verified on chain ${target.chainId}`);
  }
}
