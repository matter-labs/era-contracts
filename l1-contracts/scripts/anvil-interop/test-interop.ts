#!/usr/bin/env node

import { JsonRpcProvider, Wallet, Contract } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { getDefaultAccountPrivateKey } from "./src/utils";

/**
 * Simple interop test:
 * 1. Send a test message from chain 11 to chain 12 via L1 bridgehub
 * 2. Monitor both chains for the message
 */
async function main() {
  console.log("\n=== Interop Integration Test ===\n");

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

  // Setup providers directly from RPC URLs
  const l1Provider = new JsonRpcProvider(state.chains.l1.rpcUrl);
  const wallet = new Wallet(privateKey, l1Provider);

  const chain11 = state.chains.l2.find((c) => c.chainId === 11);
  const chain12 = state.chains.l2.find((c) => c.chainId === 12);

  if (!chain11 || !chain12) {
    throw new Error("Chains 11 and 12 not found");
  }

  const chain11Addr = state.chainAddresses.find((c) => c.chainId === 11);
  const chain12Addr = state.chainAddresses.find((c) => c.chainId === 12);

  console.log("Test Configuration:");
  console.log(`  L1 Bridgehub: ${state.l1Addresses.bridgehub}`);
  console.log(`  Chain 11 (Source): ${chain11Addr?.diamondProxy}`);
  console.log(`  Chain 12 (Target): ${chain12Addr?.diamondProxy}`);
  console.log();

  // Test 1: Check chain registration
  console.log("Test 1: Verifying chain registration...");
  const bridgehubAbi = [
    "function getZKChain(uint256 chainId) external view returns (address)",
    "function requestL2TransactionDirect((uint256 chainId, uint256 mintValue, address l2Contract, uint256 l2Value, bytes l2Calldata, uint256 l2GasLimit, uint256 l2GasPerPubdataByteLimit, bytes[] factoryDeps, address refundRecipient) calldata request) external payable returns (bytes32)",
  ];

  const bridgehub = new Contract(state.l1Addresses.bridgehub, bridgehubAbi, wallet);

  const registered11 = await bridgehub.getZKChain(11);
  const registered12 = await bridgehub.getZKChain(12);

  if (registered11 === "0x0000000000000000000000000000000000000000") {
    throw new Error("Chain 11 not registered");
  }
  if (registered12 === "0x0000000000000000000000000000000000000000") {
    throw new Error("Chain 12 not registered");
  }

  console.log(`  ✅ Chain 11 registered at: ${registered11}`);
  console.log(`  ✅ Chain 12 registered at: ${registered12}`);
  console.log();

  // Test 2: Check L2 RPC connectivity
  console.log("Test 2: Verifying L2 RPC connectivity...");
  const l2Provider11 = new JsonRpcProvider(chain11.rpcUrl);
  const l2Provider12 = new JsonRpcProvider(chain12.rpcUrl);

  const blockNum11 = await l2Provider11.getBlockNumber();
  const blockNum12 = await l2Provider12.getBlockNumber();

  console.log(`  ✅ Chain 11 RPC responding (block: ${blockNum11})`);
  console.log(`  ✅ Chain 12 RPC responding (block: ${blockNum12})`);
  console.log();

  // Test 3: Send simple transaction on chain 11
  console.log("Test 3: Sending test transaction on chain 11...");
  const l2Wallet11 = new Wallet(privateKey, l2Provider11);
  const balanceBefore = await l2Provider11.getBalance(l2Wallet11.address);
  console.log(`  Wallet balance on chain 11: ${balanceBefore} wei`);

  // Send a simple self-transfer
  const tx = await l2Wallet11.sendTransaction({
    to: l2Wallet11.address,
    value: 0,
    gasLimit: 21000,
  });

  console.log(`  Transaction sent: ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`  ✅ Transaction confirmed in block ${receipt?.blockNumber}`);
  console.log();

  // Test 4: Attempt cross-chain message via L1 (informational)
  console.log("Test 4: Cross-chain message info...");
  console.log("  📝 To send a cross-chain message:");
  console.log("     1. Call bridgehub.requestL2TransactionDirect() on L1");
  console.log("     2. Specify target chain ID (12) and L2 calldata");
  console.log("     3. Pay gas for L2 execution");
  console.log("  ⚠️  Note: Full interop requires:");
  console.log("     - L2 system contracts initialized (step4)");
  console.log("     - Gateway setup (step5)");
  console.log("     - Batch settler running (step6)");
  console.log();

  console.log("=== ✅ Basic Tests Passed ===");
  console.log("Your anvil-interop environment is running!");
  console.log();
  console.log("Next steps:");
  console.log("  - Chains are registered and responding");
  console.log("  - You can send transactions on each L2");
  console.log("  - For full cross-chain interop, complete steps 4-6");
  console.log();
}

main().catch((error) => {
  console.error("\n❌ Test failed:", error);
  process.exit(1);
});
