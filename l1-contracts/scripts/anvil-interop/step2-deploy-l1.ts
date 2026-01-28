#!/usr/bin/env node
import { DeploymentRunner } from "./src/deployment-runner";

async function main() {
  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l1) {
    throw new Error("L1 chain not found. Run 'yarn step1' first.");
  }

  const { l1Addresses, ctmAddresses } = await runner.step2DeployL1(state.chains.l1.rpcUrl);

  console.log("\n✅ L1 Core Contracts Deployed:");
  console.log(`  Bridgehub: ${l1Addresses.bridgehub}`);
  console.log(`  L1SharedBridge: ${l1Addresses.l1SharedBridge}`);
  console.log(`  Governance: ${l1Addresses.governance}`);

  console.log("\n✅ ChainTypeManager Deployed:");
  console.log(`  ChainTypeManager: ${ctmAddresses.chainTypeManager}`);

  console.log("\n✅ ChainTypeManager registered with Bridgehub");
  console.log("\n📝 Deployment info saved to outputs/state/chains.json");
  console.log("\nNext: Run 'yarn step3' to register L2 chains");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
