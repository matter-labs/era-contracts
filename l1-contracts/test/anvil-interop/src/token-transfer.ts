import { BigNumber, Contract, ethers, providers, Wallet } from "ethers";
import { DeploymentRunner } from "./deployment-runner";
import type { MultiChainTokenTransferParams, MultiChainTokenTransferResult } from "./types";
import { testnetERC20TokenAbi, interopCenterAbi, l2NativeTokenVaultAbi, interopHandlerAbi } from "./contracts";
import {
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "./const";
import { encodeNtvAssetId, encodeBridgeBurnData, encodeAssetRouterBridgehubDepositData } from "./data-encoding";

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

async function readTokenBalance(
  provider: providers.JsonRpcProvider,
  tokenAddress: string,
  walletAddress: string
): Promise<BigNumber> {
  const token = new Contract(tokenAddress, testnetERC20TokenAbi(), provider);
  return token.balanceOf(walletAddress);
}

export async function executeTokenTransfer(
  options: ExecuteTokenTransferOptions = {}
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

  const sourceTokenAddr = state.testTokens[sourceChainId];
  const targetTokenAddr = state.testTokens[targetChainId];
  if (!sourceTokenAddr || !targetTokenAddr) {
    throw new Error("Test tokens not found. Run 'yarn deploy:test-token' first.");
  }

  const privateKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
  const sourceProvider = new providers.JsonRpcProvider(sourceChain.rpcUrl);
  const targetProvider = new providers.JsonRpcProvider(targetChain.rpcUrl);
  const sourceWallet = new Wallet(privateKey, sourceProvider);
  const targetWallet = new Wallet(privateKey, targetProvider);

  const sourceToken = new Contract(sourceTokenAddr, testnetERC20TokenAbi(), sourceWallet);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, interopCenterAbi(), sourceWallet);
  const sourceVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, l2NativeTokenVaultAbi(), sourceProvider);
  const targetVault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, l2NativeTokenVaultAbi(), targetProvider);

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
  const sourceBalanceBefore = await sourceToken.balanceOf(sourceWallet.address);
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
      : await readTokenBalance(targetProvider, destinationTokenBefore, targetWallet.address);

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

  const startBlock = await targetProvider.getBlockNumber();
  const sourceTx = await interopCenter.sendBundle(destinationChainIdBytes, [callStarter], [], {
    gasLimit: 500000,
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

  log(`⏱️  [${elapsed()}] Checking if relay already delivered bundle on target chain...`);
  let targetTxHash: string | null = null;
  // Quick check: only a few attempts to see if an external relayer already delivered.
  // If not, we fall through to direct executeBundle below.
  for (let attempt = 0; attempt < 3 && !targetTxHash; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    const currentBlock = await targetProvider.getBlockNumber();
    for (let blockNum = startBlock; blockNum <= currentBlock; blockNum++) {
      const block = await targetProvider.getBlock(blockNum);
      if (!block) {
        continue;
      }
      for (const txHash of block.transactions) {
        const tx = await targetProvider.getTransaction(txHash);
        const txTo = tx?.to?.toLowerCase();
        if (txTo === L2_ASSET_ROUTER_ADDR.toLowerCase() || txTo === L2_INTEROP_HANDLER_ADDR.toLowerCase()) {
          targetTxHash = txHash;
          break;
        }
      }
      if (targetTxHash) {
        break;
      }
    }
  }

  if (targetTxHash) {
    log(`ℹ️ Bundle already appears on destination chain; skipping direct executeBundle call. [${elapsed()}]`);
  } else {
    log(`⏱️  [${elapsed()}] Executing bundle directly on destination chain via L2InteropHandler...`);
    const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, interopHandlerAbi(), targetWallet);

    const mockProof = {
      chainId: sourceChainId,
      l1BatchNumber: 0,
      l2MessageIndex: 0,
      message: {
        txNumberInBatch: 0,
        sender: INTEROP_CENTER_ADDR,
        data: "0x",
      },
      proof: [],
    };

    const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);
    try {
      const executeTx = await interopHandler.executeBundle(bundleData, mockProof, { gasLimit: 5_000_000 });
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
  const sourceBalanceAfter = await sourceToken.balanceOf(sourceWallet.address);
  const destinationToken = await targetVault.tokenAddress(assetId);
  const destinationBalanceAfter =
    destinationToken === ethers.constants.AddressZero
      ? BigNumber.from(0)
      : await readTokenBalance(targetProvider, destinationToken, targetWallet.address);

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
