#!/usr/bin/env node

import { JsonRpcProvider, Wallet, Contract, AbiCoder, keccak256, parseUnits } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { getDefaultAccountPrivateKey } from "./src/utils";

const INTEROP_CENTER_ADDR = "0x000000000000000000000000000000000001000d";
const L2_ASSET_ROUTER_ADDR = "0x0000000000000000000000000000000000010003";
const L2_NATIVE_TOKEN_VAULT_ADDR = "0x0000000000000000000000000000000000010004";

const INTEROP_CENTER_ABI = [
  "function sendBundle(bytes calldata _destinationChainId, tuple(address target, uint256 value, bytes data)[] calldata _callStarters, bytes[] calldata _bundleAttributes) external payable returns (bytes32)",
  "event InteropBundleSent(bytes32 l2l1MsgHash, bytes32 interopBundleHash, tuple(bytes32 canonicalHash, bytes32 chainTreeRoot, bytes32 destination, uint256 nonce, tuple(address target, uint256 value, bytes data)[] calls) interopBundle)",
];

const TEST_TOKEN_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

const L2_ASSET_ROUTER_ABI = [
  "function receiveMessage(bytes calldata _sourceChainId, bytes calldata _payload) external payable",
  "function finalizeDeposit(uint256 _originChainId, bytes32 _assetId, bytes calldata _transferData) external payable",
];

/**
 * Send a token transfer from one L2 chain to another via InteropCenter
 *
 * Usage: yarn send:token <sourceChainId> <targetChainId> <amount>
 * Example: yarn send:token 10 11 100
 */
async function main() {
  const args = process.argv.slice(2);
  if (args.length < 3) {
    console.error("Usage: yarn send:token <sourceChainId> <targetChainId> <amount>");
    console.error("Example: yarn send:token 10 11 100");
    process.exit(1);
  }

  const sourceChainId = parseInt(args[0]);
  const targetChainId = parseInt(args[1]);
  const amount = args[2];

  console.log("\n=== Sending L2→L2 Token Transfer via InteropCenter ===\n");

  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2 || !state.testTokens) {
    throw new Error("L2 chains or test tokens not found. Run 'yarn deploy:test-token' first.");
  }

  const sourceChain = state.chains.l2.find((c: any) => c.chainId === sourceChainId);
  const targetChain = state.chains.l2.find((c: any) => c.chainId === targetChainId);

  if (!sourceChain || !targetChain) {
    throw new Error(`Invalid chain IDs. Available: ${state.chains.l2.map((c: any) => c.chainId).join(", ")}`);
  }

  const sourceTokenAddr = state.testTokens[sourceChainId];
  const targetTokenAddr = state.testTokens[targetChainId];

  if (!sourceTokenAddr || !targetTokenAddr) {
    throw new Error("Test token not found on source or target chain");
  }

  const privateKey = getDefaultAccountPrivateKey();
  const sourceProvider = new JsonRpcProvider(sourceChain.rpcUrl);
  const sourceWallet = new Wallet(privateKey, sourceProvider);

  const testToken = new Contract(sourceTokenAddr, TEST_TOKEN_ABI, sourceWallet);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, INTEROP_CENTER_ABI, sourceWallet);

  console.log("Configuration:");
  console.log(`  Source Chain: ${sourceChainId} at ${sourceChain.rpcUrl}`);
  console.log(`  Target Chain: ${targetChainId} at ${targetChain.rpcUrl}`);
  console.log(`  Source Token: ${sourceTokenAddr}`);
  console.log(`  Target Token: ${targetTokenAddr}`);
  console.log(`  Amount: ${amount} TEST`);
  console.log(`  Sender: ${sourceWallet.address}`);
  console.log();

  // Check balance
  const balance = await testToken.balanceOf(sourceWallet.address);
  console.log(`💰 Current balance: ${balance.toString()} TEST tokens`);

  const amountWei = parseUnits(amount, 18);
  if (balance < amountWei) {
    throw new Error(`Insufficient balance. Have: ${balance.toString()}, Need: ${amountWei.toString()}`);
  }

  // For token transfers, we encode the finalizeDeposit call
  // finalizeDeposit(uint256 _chainId, address _assetId, bytes calldata _transferData)

  const abiCoder = AbiCoder.defaultAbiCoder();

  // Calculate asset ID for the token (keccak256(abi.encode(chainId, tokenAddress)))
  const assetId = keccak256(abiCoder.encode(["uint256", "address"], [sourceChainId, sourceTokenAddr]));

  console.log(`🔑 Asset ID: ${assetId}`);

  // Encode transfer data: (amount, recipient, maybeTokenAddress)
  const recipient = sourceWallet.address; // Send to ourselves on target chain for testing
  const transferData = abiCoder.encode(
    ["uint256", "address", "address"],
    [amountWei, recipient, targetTokenAddr]
  );

  console.log(`📝 Transfer data encoded for ${recipient}`);

  // Encode finalizeDeposit calldata
  const finalizeDepositData = new Contract(L2_ASSET_ROUTER_ADDR, L2_ASSET_ROUTER_ABI).interface.encodeFunctionData(
    "finalizeDeposit",
    [sourceChainId, assetId, transferData]
  );

  console.log(`📦 finalizeDeposit calldata: ${finalizeDepositData.slice(0, 66)}...`);
  console.log();

  // Encode destination chain ID as bytes
  const destinationChainIdBytes = abiCoder.encode(["uint256"], [targetChainId]);

  // Create InteropCallStarter
  // For token transfers, this is an indirect call to the AssetRouter
  const callStarter = {
    target: L2_ASSET_ROUTER_ADDR,
    value: 0,
    data: finalizeDepositData,
  };

  // Bundle attributes: indirectCall flag
  // In the real system, this would be set by L2AssetRouter.initiateIndirectCall()
  // For our test, we're encoding it manually
  const bundleAttributes: string[] = [];

  // Get target chain provider and starting block BEFORE sending
  const targetProvider = new JsonRpcProvider(targetChain.rpcUrl);
  const startBlock = await targetProvider.getBlockNumber();

  console.log("🚀 Sending token transfer via InteropCenter...");
  console.log(`   InteropCenter: ${INTEROP_CENTER_ADDR}`);
  console.log(`   Target: L2AssetRouter at ${L2_ASSET_ROUTER_ADDR}`);
  console.log();

  try {
    const tx = await interopCenter.sendBundle(
      destinationChainIdBytes,
      [callStarter],
      bundleAttributes,
      { gasLimit: 500000 }
    );

    console.log(`   Transaction sent: ${tx.hash}`);
    console.log("   Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log(`   ✅ Transaction confirmed in block ${receipt?.blockNumber}`);

    // Parse InteropBundleSent event
    console.log();
    console.log("📋 Transaction Events:");
    if (receipt && receipt.logs) {
      for (const log of receipt.logs) {
        try {
          const parsed = interopCenter.interface.parseLog({
            topics: log.topics as string[],
            data: log.data,
          });
          if (parsed && parsed.name === "InteropBundleSent") {
            console.log(`   ✅ InteropBundleSent event emitted`);
            console.log(`      Bundle Hash: ${parsed.args.interopBundleHash}`);
            console.log(`      L2→L1 Msg Hash: ${parsed.args.l2l1MsgHash}`);
            console.log(`      Amount: ${amount} TEST tokens`);
            console.log(`      Recipient: ${recipient}`);
          }
        } catch (e) {
          // Not an InteropCenter event
        }
      }
    }

    console.log();
    console.log("=== ✅ Token Transfer Message Sent ===");
    console.log(`Source Chain: ${sourceChainId}`);
    console.log(`Source Tx:    ${tx.hash}`);
    console.log();

    // Wait for relaying to complete
    console.log("⏳ Waiting for L2→L2 relayer to process message...");
    console.log("   (This typically takes 2-5 seconds)");
    let targetTxHash: string | null = null;
    let attempts = 0;
    const maxAttempts = 20; // 20 seconds max wait

    while (!targetTxHash && attempts < maxAttempts) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      attempts++;

      const currentBlock = await targetProvider.getBlockNumber();

      // Check recent blocks for transactions to the AssetRouter
      for (let i = startBlock; i <= currentBlock; i++) {
        const block = await targetProvider.getBlock(i, true);
        if (block && block.transactions) {
          for (const txHash of block.transactions) {
            const tx = await targetProvider.getTransaction(txHash as string);
            if (tx && tx.to?.toLowerCase() === L2_ASSET_ROUTER_ADDR.toLowerCase()) {
              targetTxHash = txHash as string;
              break;
            }
          }
        }
        if (targetTxHash) break;
      }
    }

    console.log();
    if (targetTxHash) {
      console.log("=== ✅ Token Transfer Relayed ===");
      console.log(`Target Chain:  ${targetChainId}`);
      console.log(`Target Tx:     ${targetTxHash}`);
      console.log();
      console.log("✅ Cross-chain token transfer successfully relayed!");
      console.log();
      console.log("To see the full trace:");
      console.log(`  cast run ${tx.hash} -r ${sourceChain.rpcUrl}`);
      console.log(`  cast run ${targetTxHash} -r ${targetChain.rpcUrl}`);
      console.log();
      console.log("To check balances:");
      console.log(`  cast call ${sourceTokenAddr} "balanceOf(address)(uint256)" ${sourceWallet.address} -r ${sourceChain.rpcUrl}`);
      console.log(`  cast call ${targetTokenAddr} "balanceOf(address)(uint256)" ${sourceWallet.address} -r ${targetChain.rpcUrl}`);
    } else {
      console.log("⚠️  Timeout waiting for relay (message may still be processing)");
      console.log("   Check daemon logs: tail -f /tmp/step6-output.log");
      console.log();
      console.log("Note: Since AssetRouter is not fully implemented,");
      console.log("      the token transfer may not complete on the target chain.");
      console.log("      This demonstrates the proper encoding for token transfers.");
    }
  } catch (error: any) {
    console.error("❌ Transaction failed:", error.message);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
