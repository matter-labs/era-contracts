#!/usr/bin/env node

import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { AnvilManager } from "./src/daemons/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";

async function main(): Promise<void> {
  // Use the anvil-interop Foundry profile which disables CBOR metadata,
  // producing deterministic bytecode across platforms (macOS vs Linux CI).
  process.env.FOUNDRY_PROFILE = "anvil-interop";

  const runner = new DeploymentRunner();
  // Clear stale state from previous runs. Without this, cached testTokens in
  // chains.json causes deployAndSetup to skip token deployment on fresh chains.
  runner.clearState();
  const anvilManager = new AnvilManager();

  try {
    // Compute output paths before starting chains, so Anvil
    // can be started with --dump-state flags from the beginning.
    const stateVersion = runner.getStateVersion();
    const stateDir = path.join(__dirname, "chain-states", stateVersion);
    // The version is validated by getStateVersion(), so this removes only the selected fixture set.
    // Starting empty ensures chains removed from config do not survive as stale snapshots.
    fs.rmSync(stateDir, { recursive: true, force: true });
    const dumpStatePaths = runner.buildDumpStatePaths(stateDir);

    // Run full deployment + test tokens + TBM with pinned inputs:
    // - blockTime 1 = match the fresh-deploy harness's known-good mining cadence
    // - timestamp 1 = fixed genesis timestamp
    // - dumpStatePaths = Anvil will dump state to these files on exit
    // Contract bytecode and addresses are deterministic. Interval mining makes the final block height
    // and block-indexed state wall-clock-dependent; compare-chain-states.ts normalizes that documented
    // drift in CI.
    const { l1Addresses, ctmAddresses, chainAddresses } = await runner.deployAndSetupWithTBM(anvilManager, {
      startChainOptions: { blockTime: 1, timestamp: 1, dumpStatePaths },
    });

    const stateAfterSetup = runner.loadState();
    const testTokens = stateAfterSetup.testTokens;
    const customBaseTokens = stateAfterSetup.customBaseTokens;
    const zkToken = stateAfterSetup.zkToken;

    // Stop all chains — this triggers Anvil's --dump-state file writes.
    await runner.dumpAllStates(anvilManager, stateDir);

    // Save addresses alongside the chain states
    const addresses = {
      l1Addresses,
      ctmAddresses,
      chainAddresses,
      testTokens,
      customBaseTokens,
      zkToken,
    };
    fs.writeFileSync(path.join(stateDir, "addresses.json"), JSON.stringify(addresses, null, 2));
    console.log(`Addresses saved to ${path.join(stateDir, "addresses.json")}`);

    console.log(`\nDone. All chain states saved to chain-states/${stateVersion}/`);
  } finally {
    await anvilManager.stopAll();
    // Format generated JSON files so CI formatting checks pass.
    // Runs in finally so formatting happens even if deployment fails partway.
    console.log("\nFormatting generated files...");
    try {
      const statesGlob = path.resolve(__dirname, "chain-states/**/*.json");
      execSync(`npx prettier --write '${statesGlob}'`, { stdio: "inherit" });
    } catch {
      console.error("Warning: prettier failed");
    }
  }
}

main().catch((error) => {
  console.error("Failed:", error.message);
  process.exit(1);
});
