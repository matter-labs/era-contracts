import { expect } from "chai";
import * as assert from "assert/strict";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import { submitERC20Deposit } from "../../src/helpers/l1-deposit-submission";
import { getAbi, getCreationBytecode } from "../../src/core/contracts";
import { encodeBridgeBurnData, encodeTxDataHash } from "../../src/core/data-encoding";
import { formatEvmV1 } from "../../src/core/interop-requests";
import { withdrawETHFromL2 } from "../../src/helpers/l2-withdrawal-helper";
import { getL1BridgedOut, getL1BaseTokenAssetId } from "../../src/helpers/bridged-out-helper";
import {
  ANVIL_ACCOUNT2_PRIVATE_KEY,
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_RECIPIENT_ADDR,
  ERC20_DEPOSIT_L2_GAS_LIMIT,
  POST_UPGRADE_DEPOSIT_AMOUNT,
  TEST_TOKEN_DECIMALS,
} from "../../src/core/const";
import { getL2Chain, getChainIdByRole, createProvider } from "../../src/core/utils";

describe("02 - Direct L1<->L2 Bridge (direct-settled chain)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let directSettledChainId: number;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    directSettledChainId = getChainIdByRole(state.chains.config, "directSettled");
  });

  describe("Live deposit gas configuration", () => {
    let originalEnv: Record<string, string | undefined>;

    before(() => {
      originalEnv = {
        LIVE_DEPOSIT_L2_GAS_LIMIT: process.env.LIVE_DEPOSIT_L2_GAS_LIMIT,
        LIVE_GW_RPC: process.env.LIVE_GW_RPC,
      };
      delete process.env.LIVE_GW_RPC;
    });

    after(() => {
      for (const [name, value] of Object.entries(originalEnv)) {
        if (value === undefined) {
          delete process.env[name];
        } else {
          process.env[name] = value;
        }
      }
    });

    it("rejects missing or out-of-range gas before reading RPC configuration", async () => {
      delete process.env.LIVE_DEPOSIT_L2_GAS_LIMIT;
      await assert.rejects(runner.setupLiveState(), /LIVE_DEPOSIT_L2_GAS_LIMIT is required/);
      for (const value of ["0", "-1", ethers.constants.MaxUint256.add(1).toString()]) {
        process.env.LIVE_DEPOSIT_L2_GAS_LIMIT = value;
        await assert.rejects(runner.setupLiveState(), /LIVE_DEPOSIT_L2_GAS_LIMIT must be a positive uint256/);
      }
    });

    it("accepts a configured gas limit and proceeds to RPC configuration", async () => {
      process.env.LIVE_DEPOSIT_L2_GAS_LIMIT = ERC20_DEPOSIT_L2_GAS_LIMIT.toString();
      await assert.rejects(runner.setupLiveState(), /LIVE_GW_RPC is required/);
    });
  });

  describe("ETH deposits L1 -> L2", () => {
    it("deposits ETH from L1 to L2", async () => {
      const l1Provider = createProvider(state.chains!.l1!.rpcUrl);
      const senderAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const amount = ethers.utils.parseEther("1.0");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);
      const l2Provider = createProvider(l2Chain.rpcUrl);

      // Snapshot sender's L1 balance and recipient's L2 balance separately
      const senderL1Before = await l1Provider.getBalance(senderAddr);
      const recipientL2Before = await l2Provider.getBalance(recipientAddr);

      // Snapshot L1NativeTokenVault.bridgedOut[ETH]
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const ethAssetId = await getL1BaseTokenAssetId(state.chains!.l1!.rpcUrl, l1Ntv);
      const bridgedOutBefore = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);

      const result = await depositETHToL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        recipient: recipientAddr,
      });

      expect(result.l1TxHash).to.not.be.null;

      const senderL1After = await l1Provider.getBalance(senderAddr);
      const recipientL2After = await l2Provider.getBalance(recipientAddr);

      // L1NativeTokenVault.bridgedOut[ETH] should increase by exactly the bridged amount (mintValue).
      const bridgedOutAfter = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);
      const bridgedOutDelta = bridgedOutAfter.sub(bridgedOutBefore);
      expect(
        bridgedOutDelta.eq(result.mintValue),
        `bridgedOut[ETH] should increase by ${result.mintValue.toString()}, got ${bridgedOutDelta.toString()}`
      ).to.equal(true);

      // Sender's L1 ETH balance should decrease (by at least mintValue; gas costs add to the decrease)
      const senderL1Delta = senderL1After.sub(senderL1Before);
      expect(
        senderL1Delta.lte(result.mintValue.mul(-1)),
        `Sender L1 ETH balance should decrease by at least ${result.mintValue.toString()}, got delta ${senderL1Delta.toString()}`
      ).to.equal(true);

      // Recipient's L2 ETH balance should increase
      const recipientL2Delta = recipientL2After.sub(recipientL2Before);
      expect(
        recipientL2Delta.gt(0),
        `Recipient L2 ETH balance should increase after deposit, got delta ${recipientL2Delta.toString()}`
      ).to.equal(true);

      console.log(`   Recipient L2 ETH balance delta: ${ethers.utils.formatEther(recipientL2Delta)} ETH`);
    });
  });

  describe("ERC20 submission shared with live setup", () => {
    let signer: ethers.Wallet;
    let bridgehub: ethers.Contract;
    let token: ethers.Contract;
    const amount = POST_UPGRADE_DEPOSIT_AMOUNT;

    beforeEach(async () => {
      signer = new ethers.Wallet(ANVIL_ACCOUNT2_PRIVATE_KEY, createProvider(state.chains!.l1!.rpcUrl));
      bridgehub = new ethers.Contract(state.l1Addresses!.bridgehub, getAbi("L1Bridgehub"), signer);
      token = await new ethers.ContractFactory(
        getAbi("TestnetERC20Token"),
        getCreationBytecode("TestnetERC20Token"),
        signer
      ).deploy("Submission test", "SUBMIT", TEST_TOKEN_DECIMALS);
      await token.deployed();
      await (await token.mint(signer.address, amount)).wait();
    });

    for (const customBase of [false, true]) {
      it(`submits through the center with ${customBase ? "ERC20" : "ETH"} fee funding`, async () => {
        const chainId = customBase
          ? state.chains!.config.find((_chain) => _chain.baseToken === "custom")!.chainId
          : directSettledChainId;
        const vaultAddress = state.l1Addresses!.l1NativeTokenVault;
        const baseToken = customBase
          ? new ethers.Contract(await bridgehub.baseToken(chainId), getAbi("TestnetERC20Token"), signer)
          : undefined;
        if (baseToken) {
          await (await baseToken.mint(signer.address, amount)).wait();
        }
        const baseCustodyBefore = baseToken ? await baseToken.balanceOf(vaultAddress) : undefined;
        const baseBalanceBefore = baseToken ? await baseToken.balanceOf(signer.address) : undefined;
        const { receipt, mintValue, assetId } = await submitERC20Deposit(signer, {
          bridgehubAddress: bridgehub.address,
          chainId,
          tokenAddress: token.address,
          amount,
          l2GasLimit: ERC20_DEPOSIT_L2_GAS_LIMIT,
          recipient: ANVIL_RECIPIENT_ADDR,
        });

        const centerAddress = await bridgehub.interopCenter();
        const centerInterface = new ethers.utils.Interface(getAbi("L1InteropCenter"));
        const tx = await signer.provider.getTransaction(receipt.transactionHash);
        expect(tx.to).to.equal(centerAddress);
        expect(tx.from).to.equal(signer.address);
        expect(centerInterface.parseTransaction(tx).name).to.equal("sendMessage");
        expect(tx.value.eq(customBase ? 0 : mintValue)).to.equal(true);
        const messageLog = receipt.logs.find(
          (_log) => _log.address === centerAddress && _log.topics[0] === centerInterface.getEventTopic("MessageSent")
        )!;
        const message = centerInterface.parseLog(messageLog);
        expect(message.args.sender).to.equal(formatEvmV1(state.chains!.l1!.chainId, signer.address));
        const mailbox = new ethers.Contract(await bridgehub.getZKChain(chainId), getAbi("MailboxFacet"), signer);
        const priorityLog = receipt.logs.find(
          (_log) =>
            _log.address === mailbox.address && _log.topics[0] === mailbox.interface.getEventTopic("NewPriorityRequest")
        )!;
        const priority = mailbox.interface.parseLog(priorityLog);
        expect(message.args.sendId).to.equal(priority.args.txHash);
        expect(priority.args.transaction.reserved[0].eq(mintValue)).to.equal(true);
        expect(priority.args.transaction.gasLimit.eq(ERC20_DEPOSIT_L2_GAS_LIMIT)).to.equal(true);
        const center = new ethers.Contract(centerAddress, getAbi("L1InteropCenter"), signer);
        expect(
          (
            await center.l2TransactionBaseCost(
              chainId,
              tx.gasPrice,
              priority.args.transaction.gasLimit,
              priority.args.transaction.gasPerPubdataByteLimit
            )
          ).eq(mintValue)
        ).to.equal(true);
        expect((await token.balanceOf(signer.address)).isZero()).to.equal(true);
        expect((await token.balanceOf(vaultAddress)).eq(amount)).to.equal(true);
        expect((await token.allowance(signer.address, vaultAddress)).isZero()).to.equal(true);
        const nullifier = new ethers.Contract(state.l1Addresses!.l1NullifierProxy, getAbi("L1Nullifier"), signer);
        expect(await nullifier.depositHappened(chainId, message.args.sendId)).to.equal(
          encodeTxDataHash(signer.address, assetId, encodeBridgeBurnData(amount, ANVIL_RECIPIENT_ADDR, token.address))
        );
        if (baseToken) {
          expect((await baseToken.balanceOf(vaultAddress)).sub(baseCustodyBefore).eq(mintValue)).to.equal(true);
          expect(baseBalanceBefore.sub(await baseToken.balanceOf(signer.address)).eq(mintValue)).to.equal(true);
          expect((await baseToken.allowance(signer.address, vaultAddress)).isZero()).to.equal(true);
        }
      });
    }

    it("does not move deposit custody when the caller lacks the requested tokens", async () => {
      const chain = new ethers.Contract(await bridgehub.getZKChain(directSettledChainId), getAbi("IZKChain"), signer);
      const priorityCount = await chain.getTotalPriorityTxs();
      await assert.rejects(
        submitERC20Deposit(signer, {
          bridgehubAddress: bridgehub.address,
          chainId: directSettledChainId,
          tokenAddress: token.address,
          amount: amount.add(1),
          l2GasLimit: ERC20_DEPOSIT_L2_GAS_LIMIT,
        }),
        (_error: { receipt?: ethers.providers.TransactionReceipt }) => _error.receipt?.status === 0
      );
      expect((await token.balanceOf(signer.address)).eq(amount)).to.equal(true);
      expect((await token.balanceOf(state.l1Addresses!.l1NativeTokenVault)).isZero()).to.equal(true);
      expect((await chain.getTotalPriorityTxs()).eq(priorityCount)).to.equal(true);
    });
  });

  describe("ETH withdrawals L2 -> L1", () => {
    it("withdraws ETH from L2 to L1", async () => {
      const l1Provider = createProvider(state.chains!.l1!.rpcUrl);
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const amount = ethers.utils.parseEther("0.5");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);

      // Snapshot recipient's L1 balance
      const recipientL1Before = await l1Provider.getBalance(recipientAddr);

      // Snapshot L1NativeTokenVault.bridgedOut[ETH] before finalizing the withdrawal on L1.
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const ethAssetId = await getL1BaseTokenAssetId(state.chains!.l1!.rpcUrl, l1Ntv);
      const bridgedOutBefore = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);

      const result = await withdrawETHFromL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l1Recipient: recipientAddr,
      });

      expect(result.l2TxHash).to.not.be.null;

      const recipientL1After = await l1Provider.getBalance(recipientAddr);

      // L1NativeTokenVault.bridgedOut[ETH] should decrease by exactly the withdrawn amount.
      const bridgedOutAfter = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);
      const bridgedOutDelta = bridgedOutBefore.sub(bridgedOutAfter);
      expect(
        bridgedOutDelta.eq(amount),
        `bridgedOut[ETH] should decrease by ${amount.toString()}, got ${bridgedOutDelta.toString()}`
      ).to.equal(true);

      // Recipient's L1 ETH balance should increase by exactly the withdrawal amount
      const recipientL1Delta = recipientL1After.sub(recipientL1Before);
      expect(
        recipientL1Delta.eq(amount),
        `Recipient L1 ETH balance should increase by ${amount.toString()}, got delta ${recipientL1Delta.toString()}`
      ).to.equal(true);

      console.log(`   Recipient L1 ETH balance delta: ${ethers.utils.formatEther(recipientL1Delta)} ETH`);
    });
  });
});
