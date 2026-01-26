#!/usr/bin/env node

import { JsonRpcProvider, Wallet, AbiCoder } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { getDefaultAccountPrivateKey } from "./src/utils";

/**
 * Send a cross-chain message from one L2 chain to another L2 chain
 *
 * Usage:
 *   yarn send:l2-to-l2 [sourceChainId] [targetChainId] [targetAddress] [calldata]
 *
 * Example:
 *   yarn send:l2-to-l2 11 12 0x1234... 0xabcd...
 *   yarn send:l2-to-l2  # Uses defaults: 11 -> 12
 */
async function main() {
  console.log("\n=== Sending L2→L2 Cross-Chain Message ===\n");

  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2) {
    throw new Error("L2 chains not found. Run 'yarn step1' first.");
  }
  if (!state.chainAddresses || state.chainAddresses.length === 0) {
    throw new Error("Chain addresses not found. Run 'yarn step3' first.");
  }

  // Parse arguments
  const sourceChainId = process.argv[2] ? parseInt(process.argv[2]) : 11;
  const targetChainId = process.argv[3] ? parseInt(process.argv[3]) : 12;
  const targetAddress = process.argv[4] || "0x0000000000000000000000000000000000008006"; // ContractDeployer
  const targetCalldata = process.argv[5] || "0x"; // Empty calldata

  // Verify chains exist
  const sourceChain = state.chains.l2.find((c) => c.chainId === sourceChainId);
  const targetChain = state.chains.l2.find((c) => c.chainId === targetChainId);

  if (!sourceChain) {
    throw new Error(`Source chain ${sourceChainId} not found`);
  }
  if (!targetChain) {
    throw new Error(`Target chain ${targetChainId} not found`);
  }

  console.log("Configuration:");
  console.log(`  Source Chain: ${sourceChainId} at ${sourceChain.rpcUrl}`);
  console.log(`  Target Chain: ${targetChainId} at ${targetChain.rpcUrl}`);
  console.log(`  Target Address: ${targetAddress}`);
  console.log(`  Target Calldata: ${targetCalldata}`);
  console.log();

  const privateKey = getDefaultAccountPrivateKey();
  const sourceProvider = new JsonRpcProvider(sourceChain.rpcUrl);
  const wallet = new Wallet(privateKey, sourceProvider);

  // The L2→L2 relayer watches for transactions to this special address
  const CROSS_CHAIN_MESSENGER = "0x0000000000000000000000000000000000000420";

  // Encode the cross-chain message
  const abiCoder = AbiCoder.defaultAbiCoder();
  const messageData = abiCoder.encode(
    ["uint256", "address", "bytes"],
    [targetChainId, targetAddress, targetCalldata]
  );

  console.log("📝 Preparing cross-chain message...");
  console.log(`   Message Marker Address: ${CROSS_CHAIN_MESSENGER}`);
  console.log(`   Encoded Message Length: ${messageData.length} bytes`);
  console.log();

  console.log("🚀 Sending L2 transaction with cross-chain message...");

  try {
    // Send transaction to the special cross-chain messenger address
    // The L2→L2 relayer will detect this and relay it through L1
    const tx = await wallet.sendTransaction({
      to: CROSS_CHAIN_MESSENGER,
      value: 0,
      data: messageData,
      gasLimit: 100000,
    });

    console.log(`   Transaction sent: ${tx.hash}`);
    console.log("   Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log(`   ✅ Transaction confirmed in block ${receipt?.blockNumber}`);
    console.log();

    console.log("=== ✅ L2→L2 Message Sent ===");
    console.log(`L2 Source Tx: ${tx.hash} on chain ${sourceChainId}`);
    console.log();
    console.log("The L2→L2 relayer will:");
    console.log("  1. Detect this message on the source chain");
    console.log("  2. Relay it through L1 Bridgehub");
    console.log("  3. L1→L2 relayer will execute it on the target chain");
    console.log();
    console.log(`Check the logs to see the relaying process.`);
  } catch (error: any) {
    console.error("\n❌ Transaction failed:");
    console.error(`   ${error.message}`);

    if (error.data) {
      console.error(`   Error data: ${error.data}`);
    }

    throw error;
  }
}

main().catch((error) => {
  process.exit(1);
});
