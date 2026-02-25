#!/usr/bin/env node

import { spawnSync } from "child_process";
import * as path from "path";

const anvilInteropDir = __dirname;
const l1ContractsDir = path.resolve(__dirname, "../..");

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
      runOrThrow("yarn", ["cleanup"], anvilInteropDir, interopEnv);
      runOrThrow("yarn", ["step1"], anvilInteropDir, interopEnv);
      runOrThrow("yarn", ["step2"], anvilInteropDir, interopEnv);
      runOrThrow("yarn", ["step3"], anvilInteropDir, interopEnv);
      runOrThrow("yarn", ["step4"], anvilInteropDir, interopEnv);
      runOrThrow("yarn", ["step5"], anvilInteropDir, interopEnv);
      runOrThrow("yarn", ["deploy:test-token"], anvilInteropDir, interopEnv);
    }

    runOrThrow(
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
