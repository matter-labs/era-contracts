#!/usr/bin/env node

import { spawnSync } from "child_process";
import * as path from "path";

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

function timedRun(label: string, command: string, args: string[], cwd: string, env?: NodeJS.ProcessEnv): void {
  const start = Date.now();
  console.log(`\n⏱️  [TIMING] Starting: ${label} (total elapsed: ${elapsedSince(totalStart)})`);
  runOrThrow(command, args, cwd, env);
  console.log(`⏱️  [TIMING] Finished: ${label} in ${elapsedSince(start)} (total elapsed: ${elapsedSince(totalStart)})`);
}

async function main(): Promise<void> {
  const keepChains = process.argv.includes("--keep-chains") || process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";
  const skipSetup = process.env.ANVIL_INTEROP_SKIP_SETUP === "1";
  const skipCleanup = keepChains || process.env.ANVIL_INTEROP_SKIP_CLEANUP === "1";
  const interopEnv: NodeJS.ProcessEnv = {
    ...process.env,
    ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE: process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE || "1",
  };

  try {
    if (!skipSetup) {
      timedRun("cleanup", "yarn", ["cleanup"], anvilInteropDir, interopEnv);
      timedRun("step1 - Start Anvil chains", "yarn", ["step1"], anvilInteropDir, interopEnv);
      timedRun("step2 - Deploy L1 contracts", "yarn", ["step2"], anvilInteropDir, interopEnv);
      timedRun("step3 - Register L2 chains", "yarn", ["step3"], anvilInteropDir, interopEnv);
      timedRun("step4 - Initialize L2 system contracts", "yarn", ["step4"], anvilInteropDir, interopEnv);
      timedRun("step5 - Setup gateway", "yarn", ["step5"], anvilInteropDir, interopEnv);
      timedRun("deploy:test-token", "yarn", ["deploy:test-token"], anvilInteropDir, interopEnv);
    }

    timedRun(
      "hardhat test - token transfer",
      "yarn",
      [
        "hardhat",
        "test",
        "test/anvil-interop/test/hardhat/token-transfer.spec.ts",
        "--network",
        "hardhat",
        "--no-compile",
      ],
      l1ContractsDir,
      {
        ...interopEnv,
        ANVIL_INTEROP_SKIP_SETUP: "1",
        ANVIL_INTEROP_SKIP_CLEANUP: "1",
      }
    );

    console.log(`\n⏱️  [TIMING] Total test run: ${elapsedSince(totalStart)}`);
  } finally {
    if (!skipCleanup) {
      runOrThrow("yarn", ["cleanup"], anvilInteropDir, interopEnv);
    } else if (keepChains) {
      console.log("ℹ️ Keeping Anvil chains running (--keep-chains enabled).");
    }
  }
}

main().catch((error) => {
  console.error("❌ Hardhat interop test failed:", error.message);
  process.exit(1);
});
