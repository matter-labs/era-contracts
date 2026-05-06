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
    const version = runner.getProtocolVersionString();
    const stateDir = path.join(__dirname, "chain-states", version);
    const dumpStatePaths = runner.buildDumpStatePaths(stateDir);

    // Run full deployment + test tokens + TBM in deterministic mode:
    // - blockTime 1 = match the fresh-deploy harness's known-good mining cadence
    // - timestamp 1 = fixed genesis timestamp
    // - dumpStatePaths = Anvil will dump state to these files on exit
    // This ensures state is fully deterministic regardless of wall clock.
    // TBM is included so pregenerated state is ready for tests without re-running TBM.
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
    const addresses = { l1Addresses, ctmAddresses, chainAddresses, testTokens, customBaseTokens, zkToken };
    fs.writeFileSync(path.join(stateDir, "addresses.json"), JSON.stringify(addresses, null, 2));
    console.log(`Addresses saved to ${path.join(stateDir, "addresses.json")}`);

    console.log(`\nDone. All chain states saved to chain-states/${version}/`);
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
