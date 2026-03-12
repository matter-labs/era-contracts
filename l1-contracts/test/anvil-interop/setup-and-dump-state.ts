#!/usr/bin/env node

import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { AnvilManager } from "./src/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { deployTestTokens } from "./deploy-test-token";

async function main(): Promise<void> {
  const runner = new DeploymentRunner();
  const anvilManager = new AnvilManager();

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

  // Stop all chains — this triggers Anvil's --dump-state file writes.
  await runner.dumpAllStates(anvilManager, stateDir);

  // Save addresses alongside the chain states
  const addresses = { l1Addresses, ctmAddresses, chainAddresses, testTokens };
  fs.writeFileSync(path.join(stateDir, "addresses.json"), JSON.stringify(addresses, null, 2));
  console.log(`Addresses saved to ${path.join(stateDir, "addresses.json")}`);

  // Format generated JSON files so CI formatting checks pass
  const l1ContractsDir = path.resolve(__dirname, "../..");
  console.log("\nFormatting generated files...");
  execSync("yarn fmt", { cwd: l1ContractsDir, stdio: "inherit" });

  console.log(`\nDone. All chain states saved to chain-states/${version}/`);
}

main().catch((error) => {
  console.error("Failed:", error.message);
  process.exit(1);
});
