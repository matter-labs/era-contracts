#!/usr/bin/env node
import { DeploymentRunner } from "./src/deployment-runner";
import { getGwSettledChainIds } from "./src/utils";

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

  const gwChain = state.chains.l2?.find((c) => c.chainId === gatewayChainId);
  const gwSettledChainIds = getGwSettledChainIds(config.chains);

  // Build L2 chain RPC URL map for migration preconditions
  const l2ChainRpcUrls = new Map<number, string>();
  for (const l2Chain of state.chains.l2 || []) {
    l2ChainRpcUrls.set(l2Chain.chainId, l2Chain.rpcUrl);
  }

  const { gatewayCTMAddr } = await runner.step5SetupGateway(
    state.chains.l1.rpcUrl,
    gatewayChainId,
    state.l1Addresses,
    state.ctmAddresses,
    gwChain?.rpcUrl,
    gwSettledChainIds,
    l2ChainRpcUrls
  );

  console.log("\n✅ Gateway setup complete");
  console.log(`   CTM Address: ${gatewayCTMAddr}`);
  console.log("\nℹ️  Note: Full gateway functionality requires zkstack CLI");
  console.log("   For production setup, use: zkstack chain gateway convert-to-gateway");
  console.log("\nNext: Run 'yarn step6' to start batch settler");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
