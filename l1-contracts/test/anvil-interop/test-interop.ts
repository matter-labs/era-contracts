#!/usr/bin/env node

import { execSync } from "child_process";
import { providers } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";

/**
 * Full interop integration test:
 * 1. Ensure environment state exists
 * 2. Deploy test tokens if missing
 * 3. Execute a full L2->L2 token transfer (same path as `yarn send:token`)
 */
async function main() {
  console.log("\n=== Interop Integration Test (Full Token Transfer) ===\n");

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

  const sourceChain = state.chains.l2.find((c) => c.chainId === 11);
  const targetChain = state.chains.l2.find((c) => c.chainId === 12);
  if (!sourceChain || !targetChain) {
    throw new Error("Chains 11/12 not found in state");
  }

  // Fail fast with a clear message if chains are not running.
  try {
    await new providers.JsonRpcProvider(state.chains.l1.rpcUrl).getBlockNumber();
    await new providers.JsonRpcProvider(sourceChain.rpcUrl).getBlockNumber();
    await new providers.JsonRpcProvider(targetChain.rpcUrl).getBlockNumber();
  } catch {
    throw new Error("RPC endpoints are not reachable. Run 'yarn start' first.");
  }

  if (!state.testTokens) {
    console.log("📝 Test tokens missing, deploying them first...");
    execSync("yarn deploy:test-token", { stdio: "inherit" });
  } else {
    console.log("✅ Test tokens already deployed");
  }

  console.log("\n🚀 Executing full token transfer test (chain 11 -> chain 12, amount 10 TEST)...");
  execSync("yarn send:token 11 12 10", { stdio: "inherit" });

  console.log("\n=== ✅ Full Interop Token Transfer Test Passed ===\n");
}

main().catch((error) => {
  console.error("\n❌ Test failed:", error);
  process.exit(1);
});
