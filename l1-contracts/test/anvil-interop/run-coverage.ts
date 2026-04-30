#!/usr/bin/env node

/**
 * Runs the full Anvil interop test + coverage pipeline.
 *
 * This is the primary entry point for coverage collection. It:
 * 1. Runs cleanup
 * 2. Starts Anvil chains WITH --steps-tracing enabled
 * 3. Deploys contracts (or loads pre-generated state)
 * 4. Runs the interop tests
 * 5. Collects execution traces from the running Anvil chains
 * 6. Generates LCOV coverage report
 * 7. Cleans up Anvil chains
 *
 * Usage:
 *   ts-node run-coverage.ts [--html] [--l1-only] [--fresh-deploy]
 *
 * Environment variables:
 *   ANVIL_INTEROP_FRESH_DEPLOY=1  Force full deployment instead of pregenerated state
 *   ANVIL_INTEROP_PORT_OFFSET=N   Offset all ports by N
 */

import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { AnvilManager } from "./src/daemons/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { collectCoverage } from "./src/coverage/coverage-runner";

const anvilInteropDir = __dirname;
const l1ContractsDir = path.resolve(__dirname, "../..");
const totalStart = Date.now();

function elapsedSince(start: number): string {
  const ms = Date.now() - start;
  return `${(ms / 1000).toFixed(1)}s`;
}

function runOrThrow(command: string, args: string[], cwd: string, env?: NodeJS.ProcessEnv): void {
  const result = spawnSync(command, args, {
    cwd,
    env: env || process.env,
    stdio: "inherit",
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed with exit code ${result.status ?? "unknown"}`);
  }
}

async function timedAsync<T>(label: string, fn: () => Promise<T>): Promise<T> {
  const start = Date.now();
  console.log(`\n⏱️  [TIMING] Starting: ${label} (total elapsed: ${elapsedSince(totalStart)})`);
  const result = await fn();
  console.log(`⏱️  [TIMING] Finished: ${label} in ${elapsedSince(start)} (total elapsed: ${elapsedSince(totalStart)})`);
  return result;
}

function timedRun(label: string, command: string, args: string[], cwd: string, env?: NodeJS.ProcessEnv): void {
  const start = Date.now();
  console.log(`\n⏱️  [TIMING] Starting: ${label} (total elapsed: ${elapsedSince(totalStart)})`);
  runOrThrow(command, args, cwd, env);
  console.log(`⏱️  [TIMING] Finished: ${label} in ${elapsedSince(start)} (total elapsed: ${elapsedSince(totalStart)})`);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const html = args.includes("--html");
  const l1Only = args.includes("--l1-only");
  const freshDeploy = args.includes("--fresh-deploy") || process.env.ANVIL_INTEROP_FRESH_DEPLOY === "1";

  const portOffset = (() => {
    const idx = args.indexOf("--port-offset");
    return idx !== -1 ? parseInt(args[idx + 1], 10) : 0;
  })();
  if (portOffset) {
    process.env.ANVIL_INTEROP_PORT_OFFSET = portOffset.toString();
  }

  // Enable steps tracing for all Anvil chains started by this process
  process.env.ANVIL_COVERAGE_MODE = "1";

  console.log("📊 Anvil Interop Test + Coverage Pipeline");
  console.log("=".repeat(50));

  // Auto-discover spec files
  const specDir = path.join(anvilInteropDir, "test/hardhat");
  const allSpecFiles = fs
    .readdirSync(specDir)
    .filter((f) => /^\d+-.*\.spec\.ts$/.test(f))
    .sort()
    .map((f) => `test/anvil-interop/test/hardhat/${f}`);

  try {
    // Step 1: Cleanup
    timedRun("cleanup", "yarn", ["cleanup"], anvilInteropDir);

    // Step 2: Start chains and deploy
    const runner = new DeploymentRunner();
    const anvilManager = new AnvilManager();

    if (!freshDeploy && runner.hasChainStates()) {
      const stateDir = runner.getChainStatesDir();
      console.log(`\nFound pre-generated chain states at ${stateDir}`);
      await timedAsync("load chain states (coverage mode)", () => runner.loadChainStates(anvilManager, stateDir));
    } else {
      console.log("\nNo pre-generated chain states found, running full deployment...");
      await timedAsync("full deployment + test tokens + TBM", () => runner.deployAndSetupWithTBM(anvilManager));
    }

    // Step 3: Run tests (coverage-invisible — we collect traces afterward)
    // Tests run with --no-compile since compilation is already done
    timedRun(
      `hardhat test - ${allSpecFiles.length} interop specs`,
      "yarn",
      ["hardhat", "test", ...allSpecFiles, "--network", "hardhat", "--no-compile"],
      l1ContractsDir,
      {
        ...process.env,
        ANVIL_INTEROP_SKIP_SETUP: "1",
        ANVIL_INTEROP_SKIP_CLEANUP: "1",
      }
    );

    // Step 4: Collect coverage while chains are still running
    const runSuffix = process.env.ANVIL_INTEROP_RUN_SUFFIX || "";
    await timedAsync("coverage collection", () =>
      collectCoverage({
        projectRoot: l1ContractsDir,
        outDir: path.join(l1ContractsDir, "out"),
        statePath: path.join(anvilInteropDir, `outputs/state${runSuffix}/chains.json`),
        coverageDir: path.join(l1ContractsDir, "coverage/anvil"),
        html,
        l1Only,
      })
    );

    console.log(`\n⏱️  [TIMING] Total coverage run: ${elapsedSince(totalStart)}`);
  } finally {
    // Always cleanup
    runOrThrow("yarn", ["cleanup"], anvilInteropDir);
  }
}

main().catch((error) => {
  console.error("❌ Coverage pipeline failed:", error.message || error);
  process.exit(1);
});
