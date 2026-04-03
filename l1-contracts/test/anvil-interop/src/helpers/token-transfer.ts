import { BigNumber, Contract, ethers, providers, Wallet } from "ethers";
import { DeploymentRunner } from "../deployment-runner";
import type { MultiChainTokenTransferParams, MultiChainTokenTransferResult } from "../core/types";
import { getAbi } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  DEFAULT_TX_GAS_LIMIT,
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  INTEROP_SEND_BUNDLE_GAS_LIMIT,
  L2_ASSET_ROUTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../core/const";
import { encodeNtvAssetId, encodeBridgeBurnData, encodeAssetRouterBridgehubDepositData } from "../core/data-encoding";
import { buildMockInteropProof } from "../core/utils";
import { createBalanceTrackerFromState } from "./balance-tracker";

type Logger = (line: string) => void;

export interface ExecuteTokenTransferOptions extends MultiChainTokenTransferParams {
  logger?: Logger;
}

/**
 * Encode a chain ID in ERC-7930 format (EVM chain without address)
 */
function encodeEvmChain(chainId: number): string {
  let chainIdHex = chainId.toString(16);
  if (chainIdHex.length % 2 !== 0) chainIdHex = `0${chainIdHex}`;
  const chainRefBytes = ethers.utils.arrayify(`0x${chainIdHex}`);
  const chainRefLen = chainRefBytes.length;
  return ethers.utils.hexlify(new Uint8Array([0x00, 0x01, 0x00, 0x00, chainRefLen, ...chainRefBytes, 0x00]));
}

/**
 * Encode an address in ERC-7930 format (EVM address without chain reference)
 */
function encodeEvmAddress(address: string): string {
  const addrBytes = ethers.utils.arrayify(address);
  return ethers.utils.hexlify(new Uint8Array([0x00, 0x01, 0x00, 0x00, 0x00, 0x14, ...addrBytes]));
}

function defaultLogger(line: string): void {
  console.log(line);
}

export async function executeTokenTransfer(
  options: ExecuteTokenTransferOptions
): Promise<MultiChainTokenTransferResult> {
  const log = options.logger || defaultLogger;
  const sourceChainId = options.sourceChainId ?? 10;
  const targetChainId = options.targetChainId ?? 11;
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

  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
  const sourceProvider = new providers.JsonRpcProvider(sourceChain.rpcUrl);
  const targetProvider = new providers.JsonRpcProvider(targetChain.rpcUrl);
  const sourceWallet = new Wallet(privateKey, sourceProvider);
  const targetWallet = new Wallet(privateKey, targetProvider);
  const tracker = createBalanceTrackerFromState(state);

  const sourceToken = new Contract(sourceTokenAddr, getAbi("TestnetERC20Token"), sourceWallet);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), sourceWallet);
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
  const sourceBalanceBefore = await tracker.getL2TokenBalance(sourceChainId, sourceTokenAddr, sourceWallet.address);
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

  const abiCoder = ethers.utils.defaultAbiCoder;
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

  log(`⏱️  [${elapsed()}] Reading destination balance before...`);
  const destinationTokenBefore = await targetVault.tokenAddress(assetId);
  const destinationBalanceBefore =
    destinationTokenBefore === ethers.constants.AddressZero
      ? BigNumber.from(0)
      : await tracker.getL2TokenBalance(targetChainId, destinationTokenBefore, targetWallet.address);

  const transferData = encodeBridgeBurnData(amountWei, sourceWallet.address, sourceTokenAddr);
  const depositData = encodeAssetRouterBridgehubDepositData(assetId, transferData);

  log("\n📦 Encoded bridgehub deposit data");
  log(`   Target Chain: ${targetChainId}`);
  log(`   Asset ID: ${assetId}`);
  log(`   Recipient: ${sourceWallet.address}`);
  log(`   Amount: ${amountWei.toString()}`);

  const destinationChainIdBytes = encodeEvmChain(targetChainId);
  const targetAddressBytes = encodeEvmAddress(L2_ASSET_ROUTER_ADDR);
  const indirectCallSelector = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("indirectCall(uint256)")).slice(0, 10);
  const interopCallValueSelector = ethers.utils
    .keccak256(ethers.utils.toUtf8Bytes("interopCallValue(uint256)"))
    .slice(0, 10);
  const indirectCallAttribute = indirectCallSelector + abiCoder.encode(["uint256"], [0]).slice(2);
  const interopCallValueAttribute = interopCallValueSelector + abiCoder.encode(["uint256"], [0]).slice(2);

  const callStarter = {
    to: targetAddressBytes,
    data: depositData,
    callAttributes: [indirectCallAttribute, interopCallValueAttribute],
  };

  log(`\n⏱️  [${elapsed()}] Sending token transfer via InteropCenter...`);
  log(`   InteropCenter: ${INTEROP_CENTER_ADDR}`);
  log(`   Target: L2AssetRouter at ${L2_ASSET_ROUTER_ADDR}`);

  const sourceTx = await interopCenter.sendBundle(destinationChainIdBytes, [callStarter], [], {
    gasLimit: INTEROP_SEND_BUNDLE_GAS_LIMIT,
    value: 0,
  });
  log(`\n   Transaction sent: cast run ${sourceTx.hash} -r ${sourceChain.rpcUrl}`);
  const sourceReceipt = await sourceTx.wait();
  log(`   ✅ Transaction confirmed in block ${sourceReceipt?.blockNumber} [${elapsed()}]`);

  let interopBundle: unknown = null;
  if (sourceReceipt?.logs) {
    for (const logEntry of sourceReceipt.logs) {
      try {
        const parsed = interopCenter.interface.parseLog({
          topics: logEntry.topics as string[],
          data: logEntry.data,
        });
        if (parsed && parsed.name === "InteropBundleSent") {
          interopBundle = parsed.args["interopBundle"];
          break;
        }
      } catch {
        // Ignore non-InteropCenter logs
      }
    }
  }
  if (!interopBundle) {
    throw new Error("InteropBundleSent event not found in source transaction receipt");
  }

  let targetTxHash: string | null = null;

  {
    log(`⏱️  [${elapsed()}] Executing bundle directly on destination chain via L2InteropHandler...`);
    const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), targetWallet);

    const mockProof = buildMockInteropProof(sourceChainId);

    const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);
    try {
      const executeTx = await interopHandler.executeBundle(bundleData, mockProof, { gasLimit: DEFAULT_TX_GAS_LIMIT });
      await executeTx.wait();
      targetTxHash = executeTx.hash;
      log(`   ✅ executeBundle tx: cast run ${executeTx.hash} -r ${targetChain.rpcUrl}`);
    } catch (error: unknown) {
      const message = (error as Error)?.message || String(error);
      log(`   ⚠️ executeBundle failed: ${message}`);
      const failedTxHash = (error as { transactionHash?: string })?.transactionHash;
      if (!targetTxHash && failedTxHash) {
        targetTxHash = failedTxHash;
        log(`   ⚠️ using reverted executeBundle tx: cast run ${failedTxHash} -r ${targetChain.rpcUrl}`);
      }
    }
  }

  log(`⏱️  [${elapsed()}] Reading final balances...`);
  const sourceBalanceAfter = await tracker.getL2TokenBalance(sourceChainId, sourceTokenAddr, sourceWallet.address);
  const destinationToken = await targetVault.tokenAddress(assetId);
  const destinationBalanceAfter =
    destinationToken === ethers.constants.AddressZero
      ? BigNumber.from(0)
      : await tracker.getL2TokenBalance(targetChainId, destinationToken, targetWallet.address);

  log(`Target Chain: ${targetChainId}`);
  log(`Target Tx:    ${targetTxHash || "not found yet (relay may still be pending)"}`);
  log("");
  log("Trace commands:");
  log(`  cast run ${sourceTx.hash} -r ${sourceChain.rpcUrl}`);
  if (targetTxHash) {
    log(`  cast run ${targetTxHash} -r ${targetChain.rpcUrl}`);
  }

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
    amountWei: amountWei.toString(),
    sourceBalanceBefore: sourceBalanceBefore.toString(),
    sourceBalanceAfter: sourceBalanceAfter.toString(),
    destinationBalanceBefore: destinationBalanceBefore.toString(),
    destinationBalanceAfter: destinationBalanceAfter.toString(),
    sourceTxHash: sourceTx.hash,
    targetTxHash,
  };
}
