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

  await runner.step3RegisterChains(
    state.chains.l1.rpcUrl,
    state.chains.l2,
    state.chains.config,
    state.l1Addresses,
    state.ctmAddresses
  );

  console.log("\n📝 Chain addresses saved to outputs/state/chains.json");
  console.log("\nNext: Run 'yarn start' for full setup or continue with manual steps");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
