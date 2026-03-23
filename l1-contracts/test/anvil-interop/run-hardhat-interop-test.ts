#!/usr/bin/env node

import { spawn, spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { AnvilManager } from "./src/daemons/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { getChainIdsByRole } from "./src/core/utils";
import { registerAndMigrateTestTokens } from "./src/helpers/token-balance-migration-helper";

const anvilInteropDir = __dirname;
const l1ContractsDir = path.resolve(__dirname, "../..");
// Auto-discover spec files from the test/hardhat directory.
// Files matching NN-*.spec.ts are included in order.
const specDir = path.join(anvilInteropDir, "test/hardhat");
const allSpecFiles = fs
  .readdirSync(specDir)
  .filter((f) => /^\d+-.*\.spec\.ts$/.test(f))
  .sort()
  .map((f) => `test/anvil-interop/test/hardhat/${f}`);
const parallelSpecGroups = allSpecFiles.map((spec) => [spec]);

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

function parsePortOffset(argv: string[]): number {
  const portOffsetIdx = argv.indexOf("--port-offset");
  return portOffsetIdx !== -1 ? parseInt(argv[portOffsetIdx + 1], 10) : 0;
}

function readLogTail(logPath: string, maxLines = 40): string {
  if (!fs.existsSync(logPath)) {
    return "log file not found";
  }

  const lines = fs.readFileSync(logPath, "utf-8").trimEnd().split("\n");
  return lines.slice(-maxLines).join("\n");
}

async function runParallelWorker(label: string, specs: string[], portOffset: number): Promise<void> {
  const runSuffix = `-p${portOffset}`;
  const logsDir = path.join(anvilInteropDir, `outputs/logs${runSuffix}`);
  fs.mkdirSync(logsDir, { recursive: true });
  const logPath = path.join(logsDir, `${label.replace(/\s+/g, "-")}.log`);
  const logStream = fs.createWriteStream(logPath, { flags: "w" });

  const specNames = specs.map((s) => path.basename(s, ".spec.ts"));
  console.log(
    `\n⏱️  [TIMING] Starting: ${label} [${specNames.join(", ")}] (offset ${portOffset}, total elapsed: ${elapsedSince(totalStart)})`
  );
  console.log(`   log: ${logPath}`);

  const workerArgs = [
    "test/anvil-interop/run-hardhat-interop-test.ts",
    "--port-offset",
    portOffset.toString(),
    ...specs.flatMap((spec) => ["--spec", spec]),
  ];

  await new Promise<void>((resolve, reject) => {
    const child = spawn("ts-node", workerArgs, {
      cwd: l1ContractsDir,
      env: {
        ...process.env,
        ANVIL_INTEROP_PARALLEL_WORKER: "1",
        ANVIL_INTEROP_RUN_SUFFIX: runSuffix,
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
        const tail = readLogTail(logPath);
        reject(
          new Error(
            `${label} failed with exit code ${code ?? "unknown"}. Log: ${logPath}\n` +
              `--- ${label} log tail ---\n${tail}\n--- end log tail ---`
          )
        );
      }
    });
  });
}

async function main(): Promise<void> {
  const keepChains = process.argv.includes("--keep-chains") || process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";
  const skipSetup = process.env.ANVIL_INTEROP_SKIP_SETUP === "1";
  const skipCleanup = keepChains || process.env.ANVIL_INTEROP_SKIP_CLEANUP === "1";
  const requestedSpecs = parseRequestedSpecs(process.argv.slice(2));
  const workerMode = process.env.ANVIL_INTEROP_PARALLEL_WORKER === "1";
  const freshDeploy = process.env.ANVIL_INTEROP_FRESH_DEPLOY === "1";

  // Parse --port-offset <N> flag and propagate via env var
  const portOffset = parsePortOffset(process.argv.slice(2));
  if (portOffset) {
    process.env.ANVIL_INTEROP_PORT_OFFSET = portOffset.toString();
  }

  const shouldParallelize = !workerMode && !keepChains && !skipSetup && !freshDeploy && requestedSpecs.length === 0;

  if (shouldParallelize) {
    await timedAsync("parallel hardhat interop workers", async () => {
      await Promise.all(
        parallelSpecGroups.map((specs, index) =>
          runParallelWorker(`worker ${index + 1}`, specs, portOffset + index * 100)
        )
      );
    });
    console.log(`\n⏱️  [TIMING] Total test run: ${elapsedSince(totalStart)}`);
    return;
  }

  const specsToRun = requestedSpecs.length > 0 ? requestedSpecs : allSpecFiles;

  try {
    if (!skipSetup) {
      // Cleanup previous state (still uses shell script for process killing)
      timedRun("cleanup", "yarn", ["cleanup"], anvilInteropDir);

      const runner = new DeploymentRunner();
      const anvilManager = new AnvilManager();
      const config = runner.getConfig();

      let chains: Awaited<ReturnType<typeof runner.runFullDeployment>>["chains"];
      let l1Addresses: Awaited<ReturnType<typeof runner.runFullDeployment>>["l1Addresses"];

      // Try loading pre-generated chain states (much faster — skips deploy steps 2-5)
      // Set ANVIL_INTEROP_FRESH_DEPLOY=1 to force full deployment instead.
      if (!freshDeploy && runner.hasChainStates()) {
        const stateDir = runner.getChainStatesDir();
        console.log(`\nFound pre-generated chain states at ${stateDir}`);
        const result = await timedAsync("load chain states", () => runner.loadChainStates(anvilManager, stateDir));
        chains = result.chains;
        l1Addresses = result.l1Addresses;
      } else {
        console.log("\nNo pre-generated chain states found, running full deployment...");
        // deployAndSetup runs full deployment + deploys test tokens in one call.
        const result = await timedAsync("full deployment + test tokens (steps 1-5)", () =>
          runner.deployAndSetup(anvilManager)
        );
        chains = result.chains;
        l1Addresses = result.l1Addresses;
      }

      if (!chains.l1) {
        throw new Error("L1 chain not found");
      }

      const gatewayConfig = config.chains.find((c) => c.role === "gateway");
      const gatewayChainId = gatewayConfig?.chainId;
      const gwChain = chains.l2.find((c) => c.chainId === gatewayChainId);
      const gwSettledChainIds = getChainIdsByRole(config.chains, "gwSettled");

      // Build L2 chain RPC URL map for migration preconditions
      const l2ChainRpcUrls = new Map<number, string>();
      for (const l2Chain of chains.l2) {
        l2ChainRpcUrls.set(l2Chain.chainId, l2Chain.rpcUrl);
      }

      // Run Token Balance Migration (TBM) for test tokens on GW-settled chains.
      // Test tokens are native to their respective L2 chains. After gateway migration,
      // outgoing transfers from GW-settled chains require assetMigrationNumber == migrationNumber.
      // The real TBM flow (L2→L1→GW+L2 confirmations) properly sets assetMigrationNumber.
      if (gwSettledChainIds.length > 0 && gwChain?.rpcUrl) {
        const freshState = runner.loadState();
        if (freshState.testTokens && Object.keys(freshState.testTokens).length > 0) {
          const gwDiamondProxy = freshState.chainAddresses!.find((c) => c.chainId === gatewayChainId)!.diamondProxy;

          await timedAsync("TBM for test tokens on GW-settled chains", () =>
            registerAndMigrateTestTokens({
              gwSettledChainIds,
              l2ChainRpcUrls,
              testTokens: freshState.testTokens!,
              l1RpcUrl: chains.l1!.rpcUrl,
              gwRpcUrl: gwChain!.rpcUrl,
              l1AssetTrackerAddr: l1Addresses.l1AssetTracker,
              gwDiamondProxyAddr: gwDiamondProxy,
              chainAddresses: freshState.chainAddresses!,
              logger: (line) => console.log(line),
            })
          );
        }
      }
    }

    timedRun(
      `hardhat test - ${specsToRun.length} interop spec${specsToRun.length === 1 ? "" : "s"}`,
      "yarn",
      ["hardhat", "test", ...specsToRun, "--network", "hardhat", "--no-compile"],
      l1ContractsDir,
      {
        ...process.env,
        ANVIL_INTEROP_SKIP_SETUP: "1",
        ANVIL_INTEROP_SKIP_CLEANUP: "1",
      }
    );

    console.log(`\n⏱️  [TIMING] Total test run: ${elapsedSince(totalStart)}`);
  } finally {
    if (!skipCleanup) {
      runOrThrow("yarn", ["cleanup"], anvilInteropDir);
    } else if (keepChains) {
      console.log("ℹ️ Keeping Anvil chains running (--keep-chains enabled).");
    }
  }
}

main().catch((error) => {
  console.error("❌ Hardhat interop test failed:", error.message);
  process.exit(1);
});
