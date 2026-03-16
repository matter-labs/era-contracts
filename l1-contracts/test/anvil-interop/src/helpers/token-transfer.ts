import { BigNumber, Contract, ethers, providers, Wallet } from "ethers";
import { DeploymentRunner } from "../deployment-runner";
import type { MultiChainTokenTransferParams, MultiChainTokenTransferResult } from "../core/types";
import { testnetERC20TokenAbi, interopCenterAbi, l2NativeTokenVaultAbi, interopHandlerAbi } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../core/const";
import {
  encodeBridgeBurnData,
  encodeAssetRouterBridgehubDepositData,
  encodeEvmChain,
  encodeEvmAddress,
} from "../core/data-encoding";
import { buildMockInteropProof } from "../core/utils";
import { createBalanceTrackerFromState } from "./balance-tracker";

type Logger = (line: string) => void;

export interface ExecuteTokenTransferOptions extends MultiChainTokenTransferParams {
  logger?: Logger;
}

function defaultLogger(line: string): void {
  console.log(line);
}

/**
 * Addresses used by a token transfer — either system (public) or user-deployed (private).
 */
export interface InteropAddresses {
  ntv: string;
  assetRouter: string;
  interopCenter: string;
  interopHandler: string;
}

/**
 * Returns the system interop addresses used for public transfers.
 */
export function systemInteropAddresses(): InteropAddresses {
  return {
    ntv: L2_NATIVE_TOKEN_VAULT_ADDR,
    assetRouter: L2_ASSET_ROUTER_ADDR,
    interopCenter: INTEROP_CENTER_ADDR,
    interopHandler: L2_INTEROP_HANDLER_ADDR,
  };
}

/**
 * Core token transfer logic shared by public and private interop.
 */
export async function executeInteropTokenTransfer(opts: {
  sourceChainId: number;
  targetChainId: number;
  amount: string;
  sourceTokenAddress: string;
  sourceAddresses: InteropAddresses;
  targetAddresses: InteropAddresses;
  logger?: Logger;
}): Promise<MultiChainTokenTransferResult> {
  const log = opts.logger || defaultLogger;
  const startTime = Date.now();
  const elapsed = () => `${((Date.now() - startTime) / 1000).toFixed(1)}s`;
  const { sourceChainId, targetChainId, amount, sourceAddresses, targetAddresses } = opts;

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

  const sourceTokenAddr = opts.sourceTokenAddress;
  const sourceProvider = new providers.JsonRpcProvider(sourceChain.rpcUrl);
  const targetProvider = new providers.JsonRpcProvider(targetChain.rpcUrl);
  const sourceWallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, sourceProvider);
  const targetWallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, targetProvider);
  const tracker = createBalanceTrackerFromState(state);

  const { getAbi } = await import("../core/contracts");

  const sourceToken = new Contract(sourceTokenAddr, getAbi("TestnetERC20Token"), sourceWallet);
  const interopCenter = new Contract(sourceAddresses.interopCenter, getAbi("InteropCenter"), sourceWallet);
  const sourceVault = new Contract(sourceAddresses.ntv, getAbi("L2NativeTokenVault"), sourceProvider);
  const targetVault = new Contract(targetAddresses.ntv, getAbi("L2NativeTokenVault"), targetProvider);

  const amountWei = ethers.utils.parseUnits(amount, 18);

  // Check balance
  const sourceBalanceBefore = await tracker.getL2TokenBalance(sourceChainId, sourceTokenAddr, sourceWallet.address);
  log(`  Source balance: ${sourceBalanceBefore.toString()}`);
  if (sourceBalanceBefore.lt(amountWei)) {
    throw new Error(`Insufficient balance. Have: ${sourceBalanceBefore.toString()}, Need: ${amountWei.toString()}`);
  }

  // Approve
  const currentAllowance = await sourceToken.allowance(sourceWallet.address, sourceAddresses.ntv);
  if (currentAllowance.lt(amountWei)) {
    const approveTx = await sourceToken.approve(sourceAddresses.ntv, amountWei);
    await approveTx.wait();
    log(`  Approved NTV at ${sourceAddresses.ntv}`);
  }

  const abiCoder = ethers.utils.defaultAbiCoder;

  // Register token if needed
  const registeredAssetId = await sourceVault.assetId(sourceTokenAddr);
  if (registeredAssetId === ethers.constants.HashZero) {
    const sourceVaultWithWallet = sourceVault.connect(sourceWallet);
    const registerTx = await sourceVaultWithWallet.registerToken(sourceTokenAddr);
    await registerTx.wait();
    log(`  Token registered in NTV`);
  }

  // Use the NTV's registered asset ID (correct for bridged tokens where origin != source).
  // For native tokens this equals encodeNtvAssetId(sourceChainId, sourceTokenAddr).
  // For bridged tokens (minted via finalizeDeposit), the NTV stores the origin-based asset ID.
  const assetId = (await sourceVault.assetId(sourceTokenAddr)) as string;
  if (assetId === ethers.constants.HashZero) {
    throw new Error(`Asset ID not found for token ${sourceTokenAddr} on chain ${sourceChainId}`);
  }

  // Destination balance before
  const destinationTokenBefore = await targetVault.tokenAddress(assetId);
  const destinationBalanceBefore =
    destinationTokenBefore === ethers.constants.AddressZero
      ? BigNumber.from(0)
      : await tracker.getL2TokenBalance(targetChainId, destinationTokenBefore, targetWallet.address);

  // Encode deposit data
  const transferData = encodeBridgeBurnData(amountWei, sourceWallet.address, sourceTokenAddr);
  const depositData = encodeAssetRouterBridgehubDepositData(assetId, transferData);

  const destinationChainIdBytes = encodeEvmChain(targetChainId);
  const targetAddressBytes = encodeEvmAddress(targetAddresses.assetRouter);
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

  log(`  Sending bundle via InteropCenter at ${sourceAddresses.interopCenter}...`);
  const sourceTx = await interopCenter.sendBundle(destinationChainIdBytes, [callStarter], [], {
    gasLimit: 500000,
    value: 0,
  });
  log(`\n   Transaction sent: cast run ${sourceTx.hash} -r ${sourceChain.rpcUrl}`);
  const sourceReceipt = await sourceTx.wait();
  log(`  Source tx confirmed: ${sourceTx.hash}`);

  // Extract bundle from InteropBundleSent event
  let interopBundle: unknown = null;
  if (sourceReceipt?.logs) {
    for (const logEntry of sourceReceipt.logs) {
      try {
        const parsed = interopCenter.interface.parseLog({
          topics: logEntry.topics as string[],
          data: logEntry.data,
        });
        if (parsed && parsed.name === "InteropBundleSent") {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          interopBundle = (parsed.args as any).interopBundle;
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

  // Execute on destination chain
  let targetTxHash: string | null = null;

  {
    log(`  [${elapsed()}] Executing bundle on destination chain via InteropHandler...`);
    const interopHandler = new Contract(
      targetAddresses.interopHandler,
      getAbi("InteropHandler"),
      targetWallet
    );

    const mockProof = buildMockInteropProof(sourceChainId, sourceAddresses.interopCenter);

    const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);
    try {
      const executeTx = await interopHandler.executeBundle(bundleData, mockProof, { gasLimit: 5_000_000 });
      await executeTx.wait();
      targetTxHash = executeTx.hash;
      log(`   executeBundle tx: cast run ${executeTx.hash} -r ${targetChain.rpcUrl}`);
    } catch (error: unknown) {
      const message = (error as Error)?.message || String(error);
      log(`   executeBundle failed: ${message}`);
      const failedTxHash = (error as { transactionHash?: string })?.transactionHash;
      if (!targetTxHash && failedTxHash) {
        targetTxHash = failedTxHash;
        log(`   using reverted executeBundle tx: cast run ${failedTxHash} -r ${targetChain.rpcUrl}`);
      }
    }
  }

  // Final balances
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

  log(`\n  [${elapsed()}] Token transfer complete`);

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

/**
 * Execute a public interop token transfer between two chains using system contracts.
 */
export async function executeTokenTransfer(
  options: ExecuteTokenTransferOptions = {}
): Promise<MultiChainTokenTransferResult> {
  const runner = new DeploymentRunner();
  const state = runner.loadState();
  const sourceChainId = options.sourceChainId ?? 10;
  const sourceTokenAddr = options.sourceTokenAddress || state.testTokens?.[sourceChainId];
  if (!sourceTokenAddr) {
    throw new Error(`Source token not found for chain ${sourceChainId}.`);
  }

  const addrs = systemInteropAddresses();
  return executeInteropTokenTransfer({
    sourceChainId,
    targetChainId: options.targetChainId ?? 11,
    amount: options.amount || "10",
    sourceTokenAddress: sourceTokenAddr,
    sourceAddresses: addrs,
    targetAddresses: addrs,
    logger: options.logger,
  });
}
