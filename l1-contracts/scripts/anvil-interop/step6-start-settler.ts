#!/usr/bin/env node
import { JsonRpcProvider } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { sleep } from "./src/utils";

async function main() {
  const runner = new DeploymentRunner();
  const state = runner.loadState();
  const config = runner.getConfig();

  if (!state.chains?.l1 || !state.chains?.l2) {
    throw new Error("Chains not found. Run 'yarn step1' first.");
  }
  if (!state.l1Addresses || !state.ctmAddresses) {
    throw new Error("L1 deployment not found. Run 'yarn step2' first.");
  }
  if (!state.chainAddresses) {
    throw new Error("Chain addresses not found. Run 'yarn step3' first.");
  }

  // Create providers directly from RPC URLs
  const l1Provider = new JsonRpcProvider(state.chains.l1.rpcUrl);
  const l2Providers = new Map();
  const chainAddressesMap = new Map();

  for (const l2Chain of state.chains.l2) {
    const l2Provider = new JsonRpcProvider(l2Chain.rpcUrl);
    l2Providers.set(l2Chain.chainId, l2Provider);

    const addr = state.chainAddresses.find((c) => c.chainId === l2Chain.chainId);
    if (addr) {
      chainAddressesMap.set(l2Chain.chainId, addr);
    }
  }

  console.log("\n=== Step 6: Starting Daemons ===\n");

  const { settler, l1ToL2Relayer, l2ToL2Relayer } = await runner.step6StartBatchSettler(
    l1Provider,
    l2Providers,
    chainAddressesMap,
    config
  );

  console.log("\n✅ All Daemons Running");
  console.log("   L1→L2 Relayer: Monitoring L1 for cross-chain transactions");
  console.log("   L2→L2 Relayer: Monitoring L2 chains for cross-chain messages");
  console.log("   Batch Settler: Monitoring L2 chains for transactions to settle");
  console.log("\nPress Ctrl+C to stop\n");

  const cleanup = async () => {
    console.log("\n🧹 Stopping daemons...");
    await l1ToL2Relayer.stop();
    await l2ToL2Relayer.stop();
    await settler.stop();
    process.exit(0);
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);

  // Keep alive
  while (true) {
    await sleep(10000);
  }
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
