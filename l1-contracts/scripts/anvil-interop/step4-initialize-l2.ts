#!/usr/bin/env node
import { DeploymentRunner } from "./src/deployment-runner";

async function main() {
  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l1) {
    throw new Error("L1 chain not found. Run 'yarn step1' first.");
  }
  if (!state.l1Addresses || !state.ctmAddresses) {
    throw new Error("L1 deployment not found. Run 'yarn step2' first.");
  }
  if (!state.chainAddresses) {
    throw new Error("Chain addresses not found. Run 'yarn step3' first.");
  }

  await runner.step4InitializeL2(
    state.chains.l1.rpcUrl,
    state.chainAddresses,
    state.l1Addresses,
    state.ctmAddresses
  );

  console.log("\n✅ L2 System Contracts Initialized");
  console.log("\nNext: Run 'yarn step5' to setup gateway");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
