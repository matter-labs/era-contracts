#!/usr/bin/env node
import { DeploymentRunner } from "./src/deployment-runner";

async function main() {
  const runner = new DeploymentRunner();
  const state = runner.loadState();
  const config = runner.getConfig();

  if (!state.chains?.l1) {
    throw new Error("L1 chain not found. Run 'yarn step1' first.");
  }
  if (!state.l1Addresses || !state.ctmAddresses) {
    throw new Error("L1 deployment not found. Run 'yarn step2' first.");
  }
  if (!state.chainAddresses) {
    throw new Error("Chain addresses not found. Run 'yarn step3' first.");
  }

  const gatewayChainId = config.chains.find((c) => c.isGateway)?.chainId;
  if (!gatewayChainId) {
    console.log("⚠️  No gateway chain configured in anvil-config.json");
    console.log("Skipping gateway setup.");
    return;
  }

  const { gatewayCTMAddr } = await runner.step5SetupGateway(
    state.chains.l1.rpcUrl,
    gatewayChainId,
    state.l1Addresses,
    state.ctmAddresses
  );

  console.log(`\n✅ Gateway Chain ${gatewayChainId} configured`);
  console.log(`   Gateway CTM: ${gatewayCTMAddr}`);
  console.log("\nNext: Run 'yarn step6' to start batch settler");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
