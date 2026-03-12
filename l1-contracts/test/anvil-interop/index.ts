#!/usr/bin/env node

import * as fs from "fs";
import * as path from "path";
import type { providers } from "ethers";
import { AnvilManager } from "./src/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import type { BatchSettler } from "./src/batch-settler";
import type { ChainAddresses } from "./src/types";
import { sleep } from "./src/utils";

async function main() {
  console.log("🚀 Starting Multi-Chain Anvil Testing Environment\n");

  const runner = new DeploymentRunner();
  const anvilManager = new AnvilManager();
  const config = runner.getConfig();

  let settler: BatchSettler | undefined;

  const cleanup = async () => {
    console.log("\n🧹 Cleaning up...");
    if (settler) {
      await settler.stop();
    }
    await anvilManager.stopAll();
    process.exit(0);
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);

  try {
    // Try loading pre-generated chain states (much faster — skips deploy steps 2-5)
    // Set ANVIL_INTEROP_FRESH_DEPLOY=1 to force full deployment instead.
    const freshDeploy = process.env.ANVIL_INTEROP_FRESH_DEPLOY === "1";
    let result;
    if (!freshDeploy && runner.hasChainStates()) {
      const stateDir = runner.getChainStatesDir();
      console.log(`Found pre-generated chain states at ${stateDir}`);
      result = await runner.loadChainStates(anvilManager, stateDir);
    } else {
      // Steps 1-5: Full deployment (start chains, deploy L1, register+init L2, gateway)
      result = await runner.runFullDeployment(anvilManager);
    }
    const { chains, l1Addresses, ctmAddresses, chainAddresses } = result;

    const gatewayChainId = config.chains.find((c) => c.isGateway)?.chainId;

    // Step 6: Start batch settler daemon
    const l1Provider = anvilManager.getProvider(chains.l1!.chainId);
    const l2Providers: Map<number, providers.JsonRpcProvider> = new Map();
    const chainAddressesMap: Map<number, ChainAddresses> = new Map();

    for (const l2Chain of chains.l2) {
      const l2Provider = anvilManager.getProvider(l2Chain.chainId);
      l2Providers.set(l2Chain.chainId, l2Provider);

      const addr = chainAddresses.find((c) => c.chainId === l2Chain.chainId);
      if (addr) {
        chainAddressesMap.set(l2Chain.chainId, addr);
      }
    }

    const { settler: batchSettler } = await runner.startDaemons(l1Provider, l2Providers, chainAddressesMap, config);
    settler = batchSettler;

    console.log("\n=== ✅ Multi-Chain Environment Ready ===\n");
    console.log("Environment Details:");
    console.log(`  L1 Chain: ${chains.l1!.chainId} at ${chains.l1!.rpcUrl}`);
    for (const l2Chain of chains.l2) {
      const isGateway = l2Chain.chainId === gatewayChainId ? " (Gateway)" : "";
      console.log(`  L2 Chain: ${l2Chain.chainId} at ${l2Chain.rpcUrl}${isGateway}`);
    }

    // Export deployment addresses for integration tests
    const deploymentInfo = {
      bridgehub: l1Addresses.bridgehub,
      assetRouter: l1Addresses.l1SharedBridge,
      chainTypeManager: ctmAddresses.chainTypeManager,
      l1ChainId: chains.l1!.chainId,
      l2Chains: chains.l2.map((c) => ({
        chainId: c.chainId,
        rpcUrl: c.rpcUrl,
        diamondProxy: chainAddresses.find((addr) => addr.chainId === c.chainId)?.diamondProxy,
      })),
    };

    const deploymentInfoPath = path.join(__dirname, "outputs/deployment-info.json");
    fs.mkdirSync(path.dirname(deploymentInfoPath), { recursive: true });
    fs.writeFileSync(deploymentInfoPath, JSON.stringify(deploymentInfo, null, 2));
    console.log(`\n📝 Deployment info written to: ${deploymentInfoPath}`);

    console.log("\nPress Ctrl+C to stop all chains and exit.\n");

    await keepAlive();
  } catch (error) {
    console.error("\n❌ Setup failed:", error);
    await cleanup();
    process.exit(1);
  }
}

async function keepAlive(): Promise<void> {
  // eslint-disable-next-line no-constant-condition
  while (true) {
    await sleep(10000);
  }
}

main();
