import type { BigNumber } from "ethers";
import { Contract, Wallet, ethers } from "ethers";
import { expect } from "chai";
import type { CoreDeployedAddresses } from "../core/types";
import { extractAndRelayNewPriorityRequests, createProvider } from "../core/utils";
import { getAbi } from "../core/contracts";
import { expectBalanceDelta, expectEvent, expectNativeSpend, expectSuccessfulReceipt } from "./balance-helpers";
import { getL1BaseTokenAssetId, getL1BridgedOut } from "./bridged-out-helper";
import { getInteropSourceAddress, getInteropSourcePrivateKey } from "../core/accounts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT,
  ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
  ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  ETH_TOKEN_ADDRESS,
} from "../core/const";
import { runtimeConfig } from "../core/runtime-config";
import { encodeAssetRouterBridgehubDepositData, encodeBridgeBurnData, encodeNtvAssetId } from "../core/data-encoding";

export interface DepositETHParams {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  amount: BigNumber;
  recipient?: string;
  /** Required only for GW-settled chains. */
  gwRpcUrl?: string;
}

export interface DepositETHResult {
  l1TxHash: string;
  l2TxHash: string | null;
  amount: BigNumber;
}

export interface DepositERC20Params {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  tokenAddress: string;
  amount: BigNumber;
  recipient?: string;
  /** Required only for GW-settled chains. */
  gwRpcUrl?: string;
}

export interface DepositERC20Result {
  l1TxHash: string;
  l2TxHash: string | null;
  amount: BigNumber;
  mintValue: BigNumber;
  assetId: string;
}

/**
 * Deposit ETH from L1 to an L2 chain via Bridgehub.requestL2TransactionDirect.
 *
 * For ETH-base-token chains, the base token deposit goes through the direct path
 * (TwoBridges rejects base token deposits with AssetIdNotSupported).
 * The settlement route is resolved from L1 Bridgehub:
 * direct-settled chains relay L1 -> L2, gateway-settled chains relay L1 -> GW -> L2
 * through nested NewPriorityRequest events.
 */
export async function depositETHToL2(params: DepositETHParams): Promise<DepositETHResult> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, amount } = params;

  const l1Provider = createProvider(l1RpcUrl);
  const l1Wallet = new Wallet(getInteropSourcePrivateKey(), l1Provider);
  const recipient = params.recipient || l1Wallet.address;

  const bridgehub = new Contract(l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Wallet);

  const l2GasLimit = ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT;
  const l2GasPerPubdataByteLimit = ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
  const gasPrice = ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI;

  const baseCost = await bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
  const mintValue = baseCost.add(amount);

  const request = {
    chainId,
    mintValue,
    l2Contract: recipient,
    l2Value: amount,
    l2Calldata: "0x",
    l2GasLimit,
    l2GasPerPubdataByteLimit,
    factoryDeps: [],
    refundRecipient: recipient,
  };

  console.log(`   Depositing ${ethers.utils.formatEther(amount)} ETH to chain ${chainId} via Direct...`);
  console.log(`   baseCost: ${baseCost.toString()}, amount: ${amount.toString()}`);

  const tx = await bridgehub.requestL2TransactionDirect(request, {
    value: mintValue,
    gasLimit: 5_000_000,
  });
  const l1Receipt = await tx.wait();

  console.log(`   L1 tx: cast run ${tx.hash} -r ${l1RpcUrl}`);

  const txHashes = await extractAndRelayNewPriorityRequests(
    l1Receipt,
    {
      l1RpcUrl,
      bridgehubAddr: l1Addresses.bridgehub,
      chainId,
      chainRpcUrl: l2RpcUrl,
      gwRpcUrl: params.gwRpcUrl,
    },
    (line) => console.log(line)
  );
  const l2TxHash = txHashes.length > 0 ? txHashes[txHashes.length - 1] : null;

  return {
    l1TxHash: tx.hash,
    l2TxHash,
    amount,
  };
}

/**
 * Deposits `amount` ETH with {@link depositETHToL2} and asserts the exact outcome: the L1 request and its L2 relay
 * succeed, L1AssetRouter reports the Bridgehub-quoted mint value, the sender pays exactly that plus gas, the
 * relayed L2 transaction sends `amount` from the sender to the recipient, who receives exactly that, and
 * L1NativeTokenVault.bridgedOut[ETH] grows by the mint value.
 */
export async function expectEthDeposit(params: DepositETHParams & { recipient: string }): Promise<void> {
  const { l1RpcUrl, chainId, l1Addresses, amount, recipient } = params;
  const sender = getInteropSourceAddress();
  const l1Provider = createProvider(l1RpcUrl);
  const l2Provider = createProvider(params.l2RpcUrl);
  const senderL1Before = await l1Provider.getBalance(sender);
  const recipientL2Before = await l2Provider.getBalance(recipient);
  const ethAssetId = await getL1BaseTokenAssetId(l1RpcUrl, l1Addresses.l1NativeTokenVault);
  const bridgedOutBefore = await getL1BridgedOut(l1RpcUrl, l1Addresses.l1NativeTokenVault, ethAssetId);
  const bridgehub = new Contract(l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Provider);
  const expectedMintValue = amount.add(
    await bridgehub.l2TransactionBaseCost(
      chainId,
      ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
      ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT,
      ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    )
  );

  const result = await depositETHToL2(params);

  const l1Receipt = await expectSuccessfulReceipt(l1Provider, result.l1TxHash, "deposit L1");
  await expectSuccessfulReceipt(l2Provider, result.l2TxHash, "deposit L2 relay");
  // The harness relays the priority request as a plain impersonated transfer, which emits no L2 event to check.
  const l2Tx = await l2Provider.getTransaction(result.l2TxHash!);
  expect(l2Tx.from, "deposit L2 relay sender").to.equal(sender);
  expect(l2Tx.to, "deposit L2 relay recipient").to.equal(recipient);
  expect(l2Tx.value.toString(), "deposit L2 relay value").to.equal(amount.toString());
  expect(l2Tx.data, "deposit L2 relay calldata").to.equal("0x");
  const initiated = expectEvent(
    l1Receipt,
    "L1AssetRouter",
    l1Addresses.l1SharedBridge,
    "BridgehubDepositBaseTokenInitiated"
  );
  expect(initiated.chainId.toNumber()).to.equal(chainId);
  expect(initiated.from).to.equal(sender);
  expect(initiated.assetId).to.equal(ethAssetId);
  expect(initiated.amount.toString()).to.equal(expectedMintValue.toString());
  const senderL1After = await l1Provider.getBalance(sender);
  expectNativeSpend(
    { native: senderL1Before },
    { native: senderL1After },
    expectedMintValue,
    l1Receipt,
    "deposit sender L1"
  );
  // The Anvil priority relay forwards l2Value exactly; bootloader fee refunds are not simulated.
  expectBalanceDelta(recipientL2Before, await l2Provider.getBalance(recipient), amount, "deposit recipient L2");
  const bridgedOutAfter = await getL1BridgedOut(l1RpcUrl, l1Addresses.l1NativeTokenVault, ethAssetId);
  expectBalanceDelta(bridgedOutBefore, bridgedOutAfter, expectedMintValue, "L1NativeTokenVault.bridgedOut[ETH]");
}

/**
 * Deposit an L1 ERC20 token to an L2 chain via Bridgehub.requestL2TransactionTwoBridges.
 *
 * This uses L1AssetRouter as the second bridge and relays the emitted priority requests
 * to the target chain (or L1 -> GW -> L2 for GW-settled chains).
 *
 * Only ETH-base-token chains are supported here, since mintValue is currently paid in ETH.
 */
export async function depositERC20ToL2(params: DepositERC20Params): Promise<DepositERC20Result> {
  const { l1RpcUrl, l2RpcUrl, chainId, l1Addresses, tokenAddress, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l1Provider = createProvider(l1RpcUrl);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const recipient = params.recipient || l1Wallet.address;

  const bridgehub = new Contract(l1Addresses.bridgehub, getAbi("L1Bridgehub"), l1Wallet);
  const assetRouter = new Contract(l1Addresses.l1SharedBridge, getAbi("L1AssetRouter"), l1Wallet);
  const nativeTokenVault = new Contract(l1Addresses.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Wallet);
  const token = new Contract(tokenAddress, getAbi("TestnetERC20Token"), l1Wallet);

  const ethAssetId = encodeNtvAssetId(runtimeConfig.l1ChainId, ETH_TOKEN_ADDRESS);
  const chainBaseTokenAssetId: string = await bridgehub.baseTokenAssetId(chainId);
  if (chainBaseTokenAssetId !== ethAssetId) {
    throw new Error(
      `depositERC20ToL2 only supports ETH-base-token chains; chain ${chainId} uses ${chainBaseTokenAssetId}`
    );
  }

  let assetId: string = await nativeTokenVault.assetId(tokenAddress);
  if (assetId === ethers.constants.HashZero) {
    const registerTx = await nativeTokenVault.registerToken(tokenAddress, { gasLimit: 500_000 });
    await registerTx.wait();
    assetId = await nativeTokenVault.assetId(tokenAddress);
  }

  // The NativeTokenVault pulls the tokens directly via `safeTransferFrom` during
  // `bridgehubDeposit` (see `NativeTokenVaultBase._depositFunds`), so the caller
  // must approve the NTV — not the asset router. (Legacy removal deleted the
  // shared-bridge token-pull path that used to require an asset-router approval.)
  const currentAllowance = await token.allowance(l1Wallet.address, l1Addresses.l1NativeTokenVault);
  if (currentAllowance.lt(amount)) {
    const approveTx = await token.approve(l1Addresses.l1NativeTokenVault, amount);
    await approveTx.wait();
  }

  const l2GasLimit = 2_000_000;
  const l2GasPerPubdataByteLimit = ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
  const gasPrice = ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI;
  const mintValue = await bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);

  const secondBridgeCalldata = encodeAssetRouterBridgehubDepositData(
    assetId,
    encodeBridgeBurnData(amount, recipient, tokenAddress)
  );

  const tx = await bridgehub.requestL2TransactionTwoBridges(
    {
      chainId,
      mintValue,
      l2Value: 0,
      l2GasLimit,
      l2GasPerPubdataByteLimit,
      refundRecipient: recipient,
      secondBridgeAddress: assetRouter.address,
      secondBridgeValue: 0,
      secondBridgeCalldata,
    },
    {
      value: mintValue,
      gasLimit: 5_000_000,
    }
  );
  const l1Receipt = await tx.wait();

  console.log(`   Depositing ${ethers.utils.formatUnits(amount, 18)} ERC20 to chain ${chainId} via TwoBridges...`);
  console.log(`   L1 tx: cast run ${tx.hash} -r ${l1RpcUrl}`);

  const txHashes = await extractAndRelayNewPriorityRequests(
    l1Receipt,
    {
      l1RpcUrl,
      bridgehubAddr: l1Addresses.bridgehub,
      chainId,
      chainRpcUrl: l2RpcUrl,
      gwRpcUrl: params.gwRpcUrl,
    },
    (line) => console.log(line)
  );
  const l2TxHash = txHashes.length > 0 ? txHashes[txHashes.length - 1] : null;

  return {
    l1TxHash: tx.hash,
    l2TxHash,
    amount,
    mintValue,
    assetId,
  };
}
