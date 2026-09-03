#!/usr/bin/env node
import { AnvilManager } from "./src/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";

async function main() {
  const runner = new DeploymentRunner();
  const anvilManager = new AnvilManager();

  const { chains } = await runner.step1StartChains(anvilManager);

  console.log("\n✅ Chains started successfully");
  console.log(`  L1 Chain: ${chains.l1?.chainId} at ${chains.l1?.rpcUrl}`);
  for (const l2Chain of chains.l2) {
    console.log(`  L2 Chain: ${l2Chain.chainId} at ${l2Chain.rpcUrl}`);
  }
  console.log("\n📝 Chain info saved to outputs/state/chains.json");
  console.log("\nNext: Run 'yarn step2' to deploy L1 contracts");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
