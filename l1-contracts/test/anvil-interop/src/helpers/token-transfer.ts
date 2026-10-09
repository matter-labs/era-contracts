import { expect } from "chai";
import type { providers } from "ethers";
import { BigNumber, Contract, ethers, Wallet } from "ethers";
import { DeploymentRunner } from "../deployment-runner";
import type { MultiChainTokenTransferParams, MultiChainTokenTransferResult } from "../core/types";
import { getAbi } from "../core/contracts";
import { encodeEvmAddress } from "./erc7930";
import {
  indirectCallAttr,
  interopCallValueAttr,
  sendInteropBundle,
  executeBundle,
  expectBundleEvent,
  getBundleStatus,
  getInteropProtocolFee,
  registerL2NativeTokenIfNeeded,
} from "./interop-helpers";
import {
  approveTokenForNtv,
  captureBalance,
  expectBalanceDelta,
  expectEvent,
  expectNativeSpend,
  expectSuccessfulReceipt,
  getTokenAddressForAsset,
  getTokenBalance,
} from "./balance-helpers";
import { getInteropSourceAddress, getInteropSourcePrivateKey } from "../core/accounts";
import {
  BundleStatus,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  TEST_TOKEN_DECIMALS,
} from "../core/const";
import { encodeNtvAssetId, encodeBridgeBurnData, encodeAssetRouterBridgehubDepositData } from "../core/data-encoding";
import { createProvider, getL2RpcUrl } from "../core/utils";

type Logger = (line: string) => void;

/** Read a plain ERC20 token balance for an address using the given provider. */
async function getL2TokenBalance(
  provider: providers.JsonRpcProvider,
  tokenAddress: string,
  walletAddress: string
): Promise<BigNumber> {
  const token = new Contract(tokenAddress, getAbi("TestnetERC20Token"), provider);
  return token.balanceOf(walletAddress);
}

export interface ExecuteTokenTransferOptions extends MultiChainTokenTransferParams {
  logger?: Logger;
}

function defaultLogger(line: string): void {
  console.log(line);
}

export async function executeTokenTransfer(
  options: ExecuteTokenTransferOptions
): Promise<MultiChainTokenTransferResult> {
  const log = options.logger || defaultLogger;
  const { sourceChainId, targetChainId } = options;
  const amount = options.amount || "10";

  const runner = new DeploymentRunner();
  const state = runner.loadState();
  if (!state.chains?.l2 || !state.testTokens) {
    throw new Error("State missing. Run 'yarn start' and 'yarn deploy:test-token' first.");
  }

  const sourceChain = state.chains.l2.find((chain) => chain.chainId === sourceChainId);
  const targetChain = state.chains.l2.find((chain) => chain.chainId === targetChainId);
  if (!sourceChain || !targetChain) {
    throw new Error(`Chain not found. Available: ${state.chains.l2.map((chain) => chain.chainId).join(", ")}`);
  }

  const sourceTokenAddr = options.sourceTokenAddress || state.testTokens[sourceChainId];
  const targetTokenAddr = state.testTokens[targetChainId];
  if (!sourceTokenAddr) {
    throw new Error(
      `Source token not found for chain ${sourceChainId}. Run 'yarn deploy:test-token' or pass sourceTokenAddress.`
    );
  }

  const sourceProvider = createProvider(sourceChain.rpcUrl);
  const targetProvider = createProvider(targetChain.rpcUrl);
  const sourceWallet = new Wallet(getInteropSourcePrivateKey(), sourceProvider);

  const sourceToken = new Contract(sourceTokenAddr, getAbi("TestnetERC20Token"), sourceWallet);
  const sourceVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), sourceProvider);
  const targetVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), targetProvider);

  const transferStart = Date.now();
  const elapsed = () => `${((Date.now() - transferStart) / 1000).toFixed(1)}s`;

  log("Configuration:");
  log(`  Source Chain: ${sourceChainId}`);
  log(`  Target Chain: ${targetChainId}`);
  log(`  Source Token: ${sourceTokenAddr}`);
  log(`  Target Token: ${targetTokenAddr}`);
  log(`  Amount: ${amount} TEST`);
  log(`  Sender: ${sourceWallet.address}`);
  log("");

  log(`⏱️  [${elapsed()}] Checking source balance...`);
  const sourceBalanceBefore = await getL2TokenBalance(sourceProvider, sourceTokenAddr, sourceWallet.address);
  log(`💰 Source balance: ${sourceBalanceBefore.toString()} TEST tokens`);
  const amountWei = ethers.utils.parseUnits(amount, 18);
  if (sourceBalanceBefore.lt(amountWei)) {
    throw new Error(`Insufficient balance. Have: ${sourceBalanceBefore.toString()}, Need: ${amountWei.toString()}`);
  }

  log(`⏱️  [${elapsed()}] Checking allowance...`);
  const currentAllowance = await sourceToken.allowance(sourceWallet.address, L2_NATIVE_TOKEN_VAULT_ADDR);
  if (currentAllowance.lt(amountWei)) {
    log(`\n📝 Approving L2NativeTokenVault to spend ${amount} TEST tokens...`);
    const approveTx = await sourceToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amountWei);
    await approveTx.wait();
    log("   ✅ Approval confirmed");
  } else {
    log(`\n✅ L2NativeTokenVault already approved for ${amount} TEST tokens`);
  }

  const assetId = encodeNtvAssetId(sourceChainId, sourceTokenAddr);
  log(`\n🔑 Asset ID: ${assetId}`);

  log(`⏱️  [${elapsed()}] Checking token registration...`);
  const registeredAssetId = await sourceVault.assetId(sourceTokenAddr);
  if (registeredAssetId === ethers.constants.HashZero) {
    log("\n📝 Registering token in L2NativeTokenVault...");
    const sourceVaultWithWallet = sourceVault.connect(sourceWallet);
    const registerTx = await sourceVaultWithWallet.registerToken(sourceTokenAddr);
    await registerTx.wait();
    log("   ✅ Token registered in L2NativeTokenVault");
  } else {
    log("\n✅ Token already registered in L2NativeTokenVault");
  }

  const transferData = encodeBridgeBurnData(amountWei, sourceWallet.address, sourceTokenAddr);
  const depositData = encodeAssetRouterBridgehubDepositData(assetId, transferData);

  log("\n📦 Encoded bridgehub deposit data");
  log(`   Target Chain: ${targetChainId}`);
  log(`   Asset ID: ${assetId}`);
  log(`   Recipient: ${sourceWallet.address}`);
  log(`   Amount: ${amountWei.toString()}`);

  const targetAddressBytes = encodeEvmAddress(L2_ASSET_ROUTER_ADDR);
  const callStarter = {
    to: targetAddressBytes,
    data: depositData,
    callAttributes: [indirectCallAttr(), interopCallValueAttr(BigNumber.from(0))],
  };

  log(`\n⏱️  [${elapsed()}] Sending token transfer via InteropCenter...`);
  log(`   Target: L2AssetRouter at ${L2_ASSET_ROUTER_ADDR}`);

  const interopFee = await getInteropProtocolFee(sourceProvider);
  const sendResult = await sendInteropBundle({
    sourceProvider,
    destinationChainId: targetChainId,
    callStarters: [callStarter],
    value: interopFee,
  });
  log(`\n   Transaction sent: cast run ${sendResult.txHash} -r ${sourceChain.rpcUrl}`);
  log(`   ✅ Transaction confirmed in block ${sendResult.receipt.blockNumber} [${elapsed()}]`);

  log(`⏱️  [${elapsed()}] Executing bundle directly on destination chain via L2InteropHandler...`);
  const targetReceipt = await executeBundle(targetProvider, sendResult.bundleData, sourceChainId);
  const targetTxHash = targetReceipt.transactionHash;
  log(`   ✅ executeBundle tx: cast run ${targetTxHash} -r ${targetChain.rpcUrl}`);

  const destinationToken = await targetVault.tokenAddress(assetId);

  log(`Target Chain: ${targetChainId}`);
  log(`Target Tx:    ${targetTxHash}`);
  log("");
  log("Trace commands:");
  log(`  cast run ${sendResult.txHash} -r ${sourceChain.rpcUrl}`);
  log(`  cast run ${targetTxHash} -r ${targetChain.rpcUrl}`);

  log(`\n⏱️  [${elapsed()}] Token transfer complete`);

  return {
    sourceChainId,
    targetChainId,
    sourceRpcUrl: sourceChain.rpcUrl,
    targetRpcUrl: targetChain.rpcUrl,
    sender: sourceWallet.address,
    sourceToken: sourceTokenAddr,
    destinationToken,
    assetId,
    sourceTxHash: sendResult.txHash,
    targetTxHash,
  };
}

/**
 * Transfers `amount` of the source chain's test token with {@link executeTokenTransfer} and asserts the exact
 * outcome: source burn and fee spend, destination mint, and the bundle's send, execution and mint events.
 */
export async function expectTokenTransfer(options: {
  sourceChainId: number;
  targetChainId: number;
  amount: BigNumber;
  logger?: Logger;
}): Promise<void> {
  const { sourceChainId, targetChainId, amount } = options;
  const state = new DeploymentRunner().loadState();
  const sourceToken = state.testTokens![sourceChainId];
  const sender = getInteropSourceAddress();
  const sourceProvider = createProvider(getL2RpcUrl(state, sourceChainId));
  const targetProvider = createProvider(getL2RpcUrl(state, targetChainId));
  const assetId = encodeNtvAssetId(sourceChainId, sourceToken);
  // Register and approve before the snapshot so the transfer's native spend is only its fee and gas.
  await registerL2NativeTokenIfNeeded(sourceProvider, sourceToken);
  await approveTokenForNtv(sourceProvider, sourceToken, amount);
  const fee = await getInteropProtocolFee(sourceProvider);
  const sourceBefore = await captureBalance(sourceProvider, sourceToken);
  const destinationTokenBefore = await getTokenAddressForAsset(targetProvider, assetId);
  const destinationBefore = await getTokenBalance(targetProvider, destinationTokenBefore, sender);
  const result = await executeTokenTransfer({
    sourceChainId,
    targetChainId,
    amount: ethers.utils.formatUnits(amount, TEST_TOKEN_DECIMALS),
    sourceTokenAddress: sourceToken,
    logger: options.logger,
  });

  const sourceReceipt = await expectSuccessfulReceipt(sourceProvider, result.sourceTxHash, "interop source");
  const targetReceipt = await expectSuccessfulReceipt(targetProvider, result.targetTxHash, "interop destination");
  const sourceAfter = await captureBalance(sourceProvider, sourceToken);
  const destinationToken = await getTokenAddressForAsset(targetProvider, assetId);
  const destinationAfter = await getTokenBalance(targetProvider, destinationToken, sender);
  expectBalanceDelta(sourceBefore.token!, sourceAfter.token!, amount.mul(-1), "interop source token");
  expectBalanceDelta(destinationBefore, destinationAfter, amount, "interop destination token");
  expectNativeSpend(sourceBefore, sourceAfter, fee, sourceReceipt, "interop source fee");

  const sent = expectEvent(sourceReceipt, "InteropCenter", INTEROP_CENTER_ADDR, "InteropBundleSent");
  expect(sent.interopBundle.sourceChainId.toNumber()).to.equal(sourceChainId);
  expect(sent.interopBundle.destinationChainId.toNumber()).to.equal(targetChainId);
  expect(sent.interopBundle.calls).to.have.length(1);
  expectBundleEvent(targetReceipt, "BundleExecuted", sent.interopBundleHash);
  expect(await getBundleStatus(targetProvider, sent.interopBundleHash)).to.equal(BundleStatus.FullyExecuted);
  const minted = expectEvent(targetReceipt, "L2NativeTokenVault", L2_NATIVE_TOKEN_VAULT_ADDR, "BridgeMint");
  expect(minted.chainId.toNumber()).to.equal(sourceChainId);
  expect(minted.assetId).to.equal(assetId);
  expect(minted.receiver).to.equal(sender);
  expect(minted.amount.toString()).to.equal(amount.toString());
}
