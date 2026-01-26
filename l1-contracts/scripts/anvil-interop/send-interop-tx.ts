#!/usr/bin/env node

import { JsonRpcProvider, Wallet, Contract, AbiCoder } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { getDefaultAccountPrivateKey } from "./src/utils";

/**
 * Send a cross-chain transaction from chain 11 to chain 12
 * This demonstrates L1 -> L2 messaging via the bridgehub
 */
async function main() {
  console.log("\n=== Sending Cross-Chain Transaction ===\n");

  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l1 || !state.chains?.l2) {
    throw new Error("Chains not found. Run 'yarn step1' first.");
  }
  if (!state.l1Addresses || !state.ctmAddresses) {
    throw new Error("L1 deployment not found. Run 'yarn step2' first.");
  }
  if (!state.chainAddresses || state.chainAddresses.length === 0) {
    throw new Error("Chain addresses not found. Run 'yarn step3' first.");
  }

  const privateKey = getDefaultAccountPrivateKey();
  const l1Provider = new JsonRpcProvider(state.chains.l1.rpcUrl);
  const wallet = new Wallet(privateKey, l1Provider);

  const targetChain = process.argv[2] ? parseInt(process.argv[2]) : 12;
  const targetChainAddr = state.chainAddresses.find((c) => c.chainId === targetChain);

  if (!targetChainAddr) {
    throw new Error(`Chain ${targetChain} not found`);
  }

  console.log("Configuration:");
  console.log(`  L1 Bridgehub: ${state.l1Addresses.bridgehub}`);
  console.log(`  Target Chain: ${targetChain}`);
  console.log(`  Target Chain Address: ${targetChainAddr.diamondProxy}`);
  console.log(`  Sender: ${wallet.address}`);
  console.log();

  // Prepare a simple L2 transaction
  // For demonstration, we'll send an empty calldata to a specific L2 contract
  const l2TargetContract = "0x0000000000000000000000000000000000008006"; // ContractDeployer system contract
  const l2Calldata = "0x"; // Empty calldata

  console.log("📝 Preparing L2 transaction request...");
  console.log(`   L2 Target Contract: ${l2TargetContract}`);
  console.log(`   L2 Calldata: ${l2Calldata || "(empty)"}`);
  console.log();

  const bridgehubAbi = [
    "function requestL2TransactionDirect((uint256 chainId, uint256 mintValue, address l2Contract, uint256 l2Value, bytes l2Calldata, uint256 l2GasLimit, uint256 l2GasPerPubdataByteLimit, bytes[] factoryDeps, address refundRecipient) calldata request) external payable returns (bytes32)",
  ];

  const bridgehub = new Contract(state.l1Addresses.bridgehub, bridgehubAbi, wallet);

  const request = {
    chainId: targetChain,
    mintValue: 0,
    l2Contract: l2TargetContract,
    l2Value: 0,
    l2Calldata: l2Calldata,
    l2GasLimit: 1000000,
    l2GasPerPubdataByteLimit: 800,
    factoryDeps: [],
    refundRecipient: wallet.address,
  };

  console.log("🚀 Sending L2 transaction request via L1 Bridgehub...");

  try {
    // Try to estimate gas first
    console.log("   Estimating gas...");
    const gasEstimate = await bridgehub.requestL2TransactionDirect.estimateGas(request, {
      value: 0,
    });
    console.log(`   Gas estimate: ${gasEstimate}`);

    // Send the transaction
    const tx = await bridgehub.requestL2TransactionDirect(request, {
      value: 0,
      gasLimit: gasEstimate * 2n, // Add buffer
    });

    console.log(`   Transaction sent: ${tx.hash}`);
    console.log("   Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log(`   ✅ Transaction confirmed in block ${receipt?.blockNumber}`);
    console.log();

    // Parse logs to find the L2 transaction hash
    if (receipt && receipt.logs) {
      console.log("📊 Transaction Logs:");
      for (const log of receipt.logs) {
        console.log(`   - Log at ${log.address}`);
        console.log(`     Topics: ${log.topics.slice(0, 2).join(", ")}...`);
      }
    }

    console.log();
    console.log("=== ✅ Cross-Chain Transaction Sent ===");
    console.log(`Check the L2 chain ${targetChain} for the executed transaction.`);
  } catch (error: any) {
    console.error("\n❌ Transaction failed:");
    console.error(`   ${error.message}`);

    if (error.data) {
      console.error(`   Error data: ${error.data}`);
    }

    console.log();
    console.log("💡 Common issues:");
    console.log("   1. L2 system contracts may not be initialized (run step4)");
    console.log("   2. Chain may not be properly set up for receiving transactions");
    console.log("   3. Gas estimation failed - the transaction may revert");
    console.log();
    console.log("🔧 For full interop functionality, ensure:");
    console.log("   - Step 4 complete: L2 system contracts initialized");
    console.log("   - Step 5 complete: Gateway setup (if using chain 11)");
    console.log("   - Step 6 running: Batch settler daemon");

    throw error;
  }
}

main().catch((error) => {
  process.exit(1);
});
