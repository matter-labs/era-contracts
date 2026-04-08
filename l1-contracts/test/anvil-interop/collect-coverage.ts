#!/usr/bin/env node

/**
 * Standalone coverage collection script.
 *
 * Usage:
 *   ts-node collect-coverage.ts [--html] [--l1-only]
 *
 * Prerequisites:
 *   - Anvil chains must be running with --steps-tracing enabled
 *   - Interop tests must have been executed against these chains
 *   - Forge compilation artifacts must exist in l1-contracts/out/
 *   - Deployment state must exist in outputs/state/chains.json
 *
 * This script collects execution traces from the running Anvil chains,
 * maps them to source code via compiler source maps, and generates
 * an LCOV coverage report.
 */

import * as path from "path";
import { collectCoverage } from "./src/coverage/coverage-runner";

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const html = args.includes("--html");
  const l1Only = args.includes("--l1-only");

  const anvilInteropDir = __dirname;
  const projectRoot = path.resolve(anvilInteropDir, "../..");
  const runSuffix = process.env.ANVIL_INTEROP_RUN_SUFFIX || "";

  const options = {
    projectRoot,
    outDir: path.join(projectRoot, "out"),
    statePath: path.join(anvilInteropDir, `outputs/state${runSuffix}/chains.json`),
    coverageDir: path.join(projectRoot, "coverage/anvil"),
    html,
    l1Only,
  };

  // Verify prerequisites
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const fs = require("fs");
  if (!fs.existsSync(options.outDir)) {
    console.error("❌ Forge output directory not found. Run 'forge build' first.");
    process.exit(1);
  }
  if (!fs.existsSync(options.statePath)) {
    console.error(`❌ Deployment state not found at ${options.statePath}.`);
    console.error("   Run interop tests with --keep-chains first, or use coverage mode.");
    process.exit(1);
  }

  const result = await collectCoverage(options);

  console.log("\n✅ Coverage collection complete.");
  console.log(`   LCOV: ${result.lcovPath}`);
  console.log(`   Summary: ${result.summaryPath}`);
}

main().catch((err) => {
  console.error("❌ Coverage collection failed:", err.message || err);
  process.exit(1);
});
