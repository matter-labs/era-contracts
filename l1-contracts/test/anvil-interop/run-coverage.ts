#!/usr/bin/env node

/**
 * Runs the full Anvil interop test + coverage pipeline.
 *
 * By default the specs are sharded across parallel workers, mirroring
 * `run-hardhat-interop-test.ts`: each worker is a child of this script that owns
 * its own set of Anvil chains (own port offset, own run suffix, own state dir),
 * runs its slice of the specs, and collects coverage from its own chains. The
 * parent then unions the per-shard LCOV files into
 * `coverage/anvil/anvil-lcov.info`, which is what `yarn coverage:merge` reads.
 *
 * Sharding is what makes this affordable in CI: the specs run against Anvil with
 * `--steps-tracing`, which is several times slower than a normal run, so running
 * all 10 specs in one serial process dominated the coverage job.
 *
 * Modes:
 *   default            shard specs across workers (see MAX_PARALLEL_WORKERS)
 *   --spec <path>      run only the given spec(s) in this process (no sharding)
 *   --serial           run every spec in this process, one Anvil set (old behavior)
 *
 * Usage:
 *   ts-node run-coverage.ts [--html] [--l1-only] [--fresh-deploy] [--serial]
 *                           [--spec <path>]... [--port-offset <N>]
 *
 * Environment variables:
 *   ANVIL_INTEROP_FRESH_DEPLOY=1           Force full deployment instead of pregenerated state
 *   ANVIL_INTEROP_PORT_OFFSET=N            Offset all ports by N
 *   ANVIL_INTEROP_MAX_PARALLEL_WORKERS=N   Cap concurrent workers (0/unset = one per spec)
 *   ANVIL_INTEROP_COVERAGE_WORKER=1        Internal: marks a sharded child process
 */

import { spawn, spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { AnvilManager } from "./src/daemons/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { collectCoverage } from "./src/coverage/coverage-runner";
import { formatMergeSummary, mergeLcovFiles } from "./src/coverage/lcov-merge";

const anvilInteropDir = __dirname;
const l1ContractsDir = path.resolve(__dirname, "../..");
const coverageRootDir = path.join(l1ContractsDir, "coverage/anvil");
const shardsDir = path.join(coverageRootDir, "shards");
const totalStart = Date.now();

/** Ports are spaced this far apart so each worker's 6 chains never collide. */
const PORT_OFFSET_PER_WORKER = 100;

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

function parseRequestedSpecs(argv: string[]): string[] {
  const specArgs: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--spec") {
      const spec = argv[i + 1];
      if (!spec) {
        throw new Error("--spec requires a file path");
      }
      specArgs.push(spec);
      i += 1;
    }
  }
  return specArgs;
}

function discoverSpecFiles(): string[] {
  const specDir = path.join(anvilInteropDir, "test/hardhat");
  return fs
    .readdirSync(specDir)
    .filter((f) => /^\d+-.*\.spec\.ts$/.test(f))
    .sort()
    .map((f) => `test/anvil-interop/test/hardhat/${f}`);
}

function readLogTail(logPath: string, maxLines = 120): string {
  if (!fs.existsSync(logPath)) {
    return "log file not found";
  }
  const lines = fs.readFileSync(logPath, "utf-8").trimEnd().split("\n");
  return lines.slice(-maxLines).join("\n");
}

/** Where a worker with the given port offset writes its LCOV. */
function shardCoverageDir(portOffset: number): string {
  return path.join(shardsDir, `p${portOffset}`);
}

async function runShardWorker(
  label: string,
  specs: string[],
  portOffset: number,
  passthroughArgs: string[]
): Promise<void> {
  const runSuffix = `-p${portOffset}`;
  const logsDir = path.join(anvilInteropDir, `outputs/logs${runSuffix}`);
  fs.mkdirSync(logsDir, { recursive: true });
  const logPath = path.join(logsDir, `${label.replace(/\s+/g, "-")}-coverage.log`);
  const logStream = fs.createWriteStream(logPath, { flags: "w" });

  const specNames = specs.map((s) => path.basename(s, ".spec.ts"));
  console.log(
    `\n⏱️  [TIMING] Starting: ${label} [${specNames.join(", ")}] (offset ${portOffset}, total elapsed: ${elapsedSince(totalStart)})`
  );
  console.log(`   log: ${logPath}`);

  const workerArgs = [
    "run-coverage.ts",
    "--port-offset",
    portOffset.toString(),
    ...specs.flatMap((spec) => ["--spec", spec]),
    ...passthroughArgs,
  ];

  await new Promise<void>((resolve, reject) => {
    const child = spawn("ts-node", workerArgs, {
      cwd: anvilInteropDir,
      env: {
        ...process.env,
        ANVIL_INTEROP_COVERAGE_WORKER: "1",
        ANVIL_INTEROP_RUN_SUFFIX: runSuffix,
        ANVIL_INTEROP_PORT_OFFSET: portOffset.toString(),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    child.stdout?.pipe(logStream);
    child.stderr?.pipe(logStream);

    child.once("error", (error) => {
      logStream.end();
      reject(new Error(`Failed to start ${label}: ${error.message}. Log: ${logPath}`));
    });
    child.once("exit", (code) => {
      logStream.end();
      if (code === 0) {
        console.log(
          `✅ ${label} [${specNames.join(", ")}] passed (offset ${portOffset}, total elapsed: ${elapsedSince(totalStart)})`
        );
        resolve();
      } else {
        console.log(
          `❌ ${label} [${specNames.join(", ")}] failed (offset ${portOffset}, total elapsed: ${elapsedSince(totalStart)})`
        );
        reject(
          new Error(
            `${label} failed with exit code ${code ?? "unknown"}. Log: ${logPath}\n` +
              `--- ${label} log tail ---\n${readLogTail(logPath)}\n--- end log tail ---`
          )
        );
      }
    });
  });
}

function generateHtmlReport(lcovPath: string): void {
  const htmlDir = path.join(coverageRootDir, "html");
  const result = spawnSync(
    "genhtml",
    [lcovPath, "-o", htmlDir, "--branch-coverage", "--ignore-errors", "category", "--ignore-errors", "inconsistent"],
    { stdio: "inherit" }
  );
  if (result.status === 0) {
    console.log(`  🌐 HTML report generated: ${htmlDir}/index.html`);
  } else {
    console.warn("  ⚠️  genhtml failed (is lcov installed?). Skipping HTML report.");
  }
}

/**
 * Parent process: shard the specs across workers, then union their LCOV files.
 */
async function runSharded(specs: string[], basePortOffset: number, passthroughArgs: string[], html: boolean) {
  // One shard per spec. Each shard runs 6 Anvil chains with --steps-tracing plus a
  // hardhat process, so running all shards at once oversubscribes small runners and
  // causes load-dependent RPC flakes. ANVIL_INTEROP_MAX_PARALLEL_WORKERS caps the
  // concurrency; unset (or 0) runs one worker per spec.
  const shardGroups = specs.map((spec) => [spec]);
  const maxWorkers = Number(process.env.ANVIL_INTEROP_MAX_PARALLEL_WORKERS || 0) || shardGroups.length;

  // Drop stale per-shard reports so a shard that fails to produce one cannot be
  // silently merged from a previous run.
  fs.rmSync(shardsDir, { recursive: true, force: true });

  console.log(`\n📊 Sharding ${specs.length} specs across up to ${maxWorkers} concurrent workers`);

  await timedAsync("parallel anvil coverage workers", async () => {
    const queue = shardGroups.map((group, index) => ({ group, index }));
    const failures: Error[] = [];
    const runNext = async (): Promise<void> => {
      const item = queue.shift();
      if (!item) return;
      try {
        await runShardWorker(
          `shard ${item.index + 1}`,
          item.group,
          basePortOffset + item.index * PORT_OFFSET_PER_WORKER,
          passthroughArgs
        );
      } catch (e) {
        failures.push(e as Error);
      }
      await runNext();
    };
    await Promise.all(Array.from({ length: Math.min(maxWorkers, queue.length) }, () => runNext()));
    if (failures.length > 0) {
      for (const failure of failures) {
        console.error(`\n${failure.message}`);
      }
      throw new Error(`${failures.length} of ${shardGroups.length} coverage shards failed`);
    }
  });

  // Union the shard reports into the path `yarn coverage:merge` expects.
  const shardLcovPaths = shardGroups.map((_, index) =>
    path.join(shardCoverageDir(basePortOffset + index * PORT_OFFSET_PER_WORKER), "anvil-lcov.info")
  );
  const missing = shardLcovPaths.filter((p) => !fs.existsSync(p));
  if (missing.length > 0) {
    throw new Error(`Coverage shards produced no LCOV:\n  ${missing.join("\n  ")}`);
  }

  const lcovPath = path.join(coverageRootDir, "anvil-lcov.info");
  const { stats } = mergeLcovFiles(shardLcovPaths, lcovPath);
  const summary = formatMergeSummary(stats, shardLcovPaths.length);
  const summaryPath = path.join(coverageRootDir, "anvil-coverage-summary.txt");
  fs.writeFileSync(summaryPath, summary);

  console.log(`\n${summary}`);
  console.log(`  📄 Merged LCOV written to: ${lcovPath}`);
  console.log(`  📄 Summary written to: ${summaryPath}`);

  if (html) {
    generateHtmlReport(lcovPath);
  }
}

/**
 * Single-process run: start one set of chains, run the given specs, collect
 * coverage from those chains. This is both the `--serial` path and the body of
 * every sharded worker.
 */
async function runSingleProcess(
  specs: string[],
  freshDeploy: boolean,
  coverageDir: string,
  html: boolean,
  l1Only: boolean
) {
  timedRun("cleanup", "yarn", ["cleanup"], anvilInteropDir);

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

  // Tests run with --no-compile since compilation is already done.
  timedRun(
    `hardhat test - ${specs.length} interop spec${specs.length === 1 ? "" : "s"}`,
    "yarn",
    ["hardhat", "test", ...specs, "--network", "hardhat", "--no-compile"],
    l1ContractsDir,
    {
      ...process.env,
      ANVIL_INTEROP_SKIP_SETUP: "1",
      ANVIL_INTEROP_SKIP_CLEANUP: "1",
    }
  );

  // Collect coverage while the chains are still running.
  const runSuffix = process.env.ANVIL_INTEROP_RUN_SUFFIX || "";
  await timedAsync("coverage collection", () =>
    collectCoverage({
      projectRoot: l1ContractsDir,
      outDir: path.join(l1ContractsDir, "out"),
      statePath: path.join(anvilInteropDir, `outputs/state${runSuffix}/chains.json`),
      coverageDir,
      html,
      l1Only,
    })
  );
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const html = args.includes("--html");
  const l1Only = args.includes("--l1-only");
  const serial = args.includes("--serial");
  const freshDeploy = args.includes("--fresh-deploy") || process.env.ANVIL_INTEROP_FRESH_DEPLOY === "1";
  const workerMode = process.env.ANVIL_INTEROP_COVERAGE_WORKER === "1";
  const requestedSpecs = parseRequestedSpecs(args);

  const portOffsetIdx = args.indexOf("--port-offset");
  const portOffset = portOffsetIdx !== -1 ? parseInt(args[portOffsetIdx + 1], 10) : 0;
  if (portOffset) {
    process.env.ANVIL_INTEROP_PORT_OFFSET = portOffset.toString();
  }

  // Enable steps tracing for all Anvil chains started by this process (and, via
  // inheritance, by any worker it spawns).
  process.env.ANVIL_COVERAGE_MODE = "1";

  console.log("📊 Anvil Interop Test + Coverage Pipeline");
  console.log("=".repeat(50));

  const specs = requestedSpecs.length > 0 ? requestedSpecs : discoverSpecFiles();

  // A fresh deployment per shard would multiply the deploy cost, so `--fresh-deploy`
  // stays serial. Explicit `--spec` selection and worker processes are single-process
  // by definition.
  const shouldShard = !workerMode && !serial && !freshDeploy && requestedSpecs.length === 0;

  try {
    if (shouldShard) {
      const passthroughArgs = l1Only ? ["--l1-only"] : [];
      await runSharded(specs, portOffset, passthroughArgs, html);
    } else {
      const coverageDir = workerMode ? shardCoverageDir(portOffset) : coverageRootDir;
      await runSingleProcess(specs, freshDeploy, coverageDir, html && !workerMode, l1Only);
    }

    console.log(`\n⏱️  [TIMING] Total coverage run: ${elapsedSince(totalStart)}`);
  } finally {
    // Each worker cleans up its own offset-scoped chains; this clears whatever ran
    // in this process (and any offset-0 leftovers in the parent).
    runOrThrow("yarn", ["cleanup"], anvilInteropDir);
  }
}

main().catch((error) => {
  console.error("❌ Coverage pipeline failed:", error.message || error);
  process.exit(1);
});
