#!/usr/bin/env node

import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { AnvilManager } from "./src/daemons/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { deployTestTokens } from "./src/helpers/deploy-test-token";
import { deployPrivateInteropStack } from "./src/helpers/private-interop-deployer";
import { getChainIdsByRole } from "./src/core/utils";
import { L1_CHAIN_ID } from "./src/core/const";
import type { PrivateInteropAddresses } from "./src/core/types";

async function main(): Promise<void> {
  // Use the anvil-interop Foundry profile which disables CBOR metadata,
  // producing deterministic bytecode across platforms (macOS vs Linux CI).
  process.env.FOUNDRY_PROFILE = "anvil-interop";

  const runner = new DeploymentRunner();
  const anvilManager = new AnvilManager();

  try {
    // Compute output paths before starting chains, so Anvil
    // can be started with --dump-state flags from the beginning.
    const version = runner.getProtocolVersionString();
    const stateDir = path.join(__dirname, "chain-states", version);
    const dumpStatePaths = runner.buildDumpStatePaths(stateDir);

    // Run full deployment in deterministic mode:
    // - blockTime 0 = instant mining (blocks mined only on transactions)
    // - timestamp 1 = fixed genesis timestamp
    // - dumpStatePaths = Anvil will dump state to these files on exit
    // This ensures state is fully deterministic regardless of wall clock.
    const { l1Addresses, ctmAddresses, chainAddresses } = await runner.runFullDeployment(anvilManager, {
      blockTime: 0,
      timestamp: 1,
      dumpStatePaths,
    });

    // Deploy test tokens before dumping state so they're included in the preloaded chain state.
    // This eliminates the need for forge build artifacts at test time.
    await deployTestTokens();
    const stateAfterTokens = runner.loadState();
    const testTokens = stateAfterTokens.testTokens;

    // Deploy private interop stack on all GW-settled chains.
    const config = runner.getConfig();
    const gwSettledChainIds = getChainIdsByRole(config.chains, "gwSettled");
    let privateInteropAddresses: Record<number, PrivateInteropAddresses> | undefined;
    if (gwSettledChainIds.length > 0) {
      privateInteropAddresses = {};
      for (const chainId of gwSettledChainIds) {
        const chain = stateAfterTokens.chains!.l2.find((c) => c.chainId === chainId);
        if (!chain) continue;
        console.log(`Deploying private interop on chain ${chainId}...`);
        privateInteropAddresses[chainId] = await deployPrivateInteropStack(
          chain.rpcUrl,
          chainId,
          L1_CHAIN_ID,
          (line) => console.log(`  [chain ${chainId}] ${line}`)
        );
      }
      const s = runner.loadState();
      s.privateInteropAddresses = privateInteropAddresses;
      runner.saveState(s);
    }

    // Stop all chains — this triggers Anvil's --dump-state file writes.
    await runner.dumpAllStates(anvilManager, stateDir);

    // Save addresses alongside the chain states
    const addresses = { l1Addresses, ctmAddresses, chainAddresses, testTokens, privateInteropAddresses };
    fs.writeFileSync(path.join(stateDir, "addresses.json"), JSON.stringify(addresses, null, 2));
    console.log(`Addresses saved to ${path.join(stateDir, "addresses.json")}`);

    console.log(`\nDone. All chain states saved to chain-states/${version}/`);
  } finally {
    // Format generated JSON files so CI formatting checks pass.
    // Runs in finally so formatting happens even if deployment fails partway.
    const l1ContractsDir = path.resolve(__dirname, "../..");
    console.log("\nFormatting generated files...");
    try {
      execSync("npx prettier --write '**/*.json'", { cwd: l1ContractsDir, stdio: "inherit" });
    } catch {
      console.error("Warning: yarn fmt failed");
    }
  }
}

main().catch((error) => {
  console.error("Failed:", error.message);
  process.exit(1);
});
