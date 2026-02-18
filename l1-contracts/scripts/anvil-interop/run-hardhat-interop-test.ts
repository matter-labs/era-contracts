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
  const setupRetries = Number(process.env.ANVIL_INTEROP_SETUP_RETRIES || "3");
  const interopEnv: NodeJS.ProcessEnv = {
    ...process.env,
    ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE: process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE || "1",
  };

  try {
    if (!skipSetup) {
      let setupError: Error | null = null;
      for (let attempt = 1; attempt <= setupRetries; attempt++) {
        try {
          console.log(`\n🔧 Setup attempt ${attempt}/${setupRetries}...`);
          runOrThrow("yarn", ["cleanup"], anvilInteropDir, interopEnv);
          runOrThrow("yarn", ["step1"], anvilInteropDir, interopEnv);
          runOrThrow("yarn", ["step2"], anvilInteropDir, interopEnv);
          runOrThrow("yarn", ["step3"], anvilInteropDir, interopEnv);
          runOrThrow("yarn", ["step4"], anvilInteropDir, interopEnv);
          runOrThrow("yarn", ["step5"], anvilInteropDir, interopEnv);
          runOrThrow("yarn", ["deploy:test-token"], anvilInteropDir, interopEnv);
          setupError = null;
          break;
        } catch (error: unknown) {
          setupError = error;
          console.error(`⚠️ Setup attempt ${attempt} failed: ${(error as Error).message}`);
          runOrThrow("yarn", ["cleanup"], anvilInteropDir, interopEnv);
        }
      }
      if (setupError) {
        throw setupError;
      }
    }

    runOrThrow(
      "yarn",
      [
        "hardhat",
        "test",
        "scripts/anvil-interop/test/hardhat/token-transfer.spec.ts",
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
