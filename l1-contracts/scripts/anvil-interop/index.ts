#!/usr/bin/env node

import * as fs from "fs";
import * as path from "path";
import type { JsonRpcProvider } from "ethers";
import { AnvilManager } from "./src/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { BatchSettler } from "./src/batch-settler";
import type { DeploymentContext, ChainAddresses } from "./src/types";
import { sleep } from "./src/utils";

async function main() {
  console.log("🚀 Starting Multi-Chain Anvil Testing Environment\n");

  const runner = new DeploymentRunner();
  const anvilManager = new AnvilManager();
  const config = runner.getConfig();

  let context: DeploymentContext | undefined;
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
    // Step 1: Start Anvil chains
    const { chains } = await runner.step1StartChains(anvilManager);

    if (!chains.l1) {
      throw new Error("L1 chain not found");
    }

    const l1Provider = anvilManager.getProvider(chains.l1.chainId);

    // Step 2: Deploy L1 contracts
    const { l1Addresses, ctmAddresses } = await runner.step2DeployL1(chains.l1.rpcUrl);

    // Step 3: Register L2 chains
    const { chainAddresses } = await runner.step3RegisterChains(
      chains.l1.rpcUrl,
      chains.l2,
      chains.config,
      l1Addresses,
      ctmAddresses
    );

    // Step 4: Initialize L2 system contracts
    await runner.step4InitializeL2(chains.l1.rpcUrl, chainAddresses, l1Addresses, ctmAddresses);

    // Step 5: Setup gateway if configured
    const gatewayChainId = config.chains.find((c) => c.isGateway)?.chainId;
    if (gatewayChainId) {
      await runner.step5SetupGateway(chains.l1.rpcUrl, gatewayChainId, l1Addresses, ctmAddresses);
    }

    // Step 6: Start batch settler daemon
    const l2Providers: Map<number, JsonRpcProvider> = new Map();
    const chainAddressesMap: Map<number, ChainAddresses> = new Map();

    for (const l2Chain of chains.l2) {
      const l2Provider = anvilManager.getProvider(l2Chain.chainId);
      l2Providers.set(l2Chain.chainId, l2Provider);

      const addr = chainAddresses.find((c) => c.chainId === l2Chain.chainId);
      if (addr) {
        chainAddressesMap.set(l2Chain.chainId, addr);
      }
    }

    settler = await runner.step6StartBatchSettler(l1Provider, l2Providers, chainAddressesMap, config);

    // Store context for potential future use
    context = {
      l1Provider,
      l2Providers,
      l1Addresses,
      ctmAddresses,
      chainAddresses: chainAddressesMap,
      gatewayChainId,
    };

    console.log("\n=== ✅ Multi-Chain Environment Ready ===\n");
    console.log("Environment Details:");
    console.log(`  L1 Chain: ${chains.l1.chainId} at ${chains.l1.rpcUrl}`);
    for (const l2Chain of chains.l2) {
      const isGateway = l2Chain.chainId === gatewayChainId ? " (Gateway)" : "";
      console.log(`  L2 Chain: ${l2Chain.chainId} at ${l2Chain.rpcUrl}${isGateway}`);
    }

    // Export deployment addresses for integration tests
    const deploymentInfo = {
      bridgehub: l1Addresses.bridgehub,
      assetRouter: l1Addresses.l1SharedBridge,
      chainTypeManager: ctmAddresses.chainTypeManager,
      l1ChainId: chains.l1.chainId,
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
