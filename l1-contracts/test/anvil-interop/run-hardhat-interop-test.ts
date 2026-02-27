#!/usr/bin/env node

import { spawnSync } from "child_process";
import * as path from "path";
import { AnvilManager } from "./src/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { deployTestTokens } from "./deploy-test-token";
import { getGwSettledChainIds } from "./src/utils";
import { registerAndMigrateTestTokens } from "./src/token-balance-migration-helper";

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
  const keepChains = process.argv.includes("--keep-chains") || process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";
  const skipSetup = process.env.ANVIL_INTEROP_SKIP_SETUP === "1";
  const skipCleanup = keepChains || process.env.ANVIL_INTEROP_SKIP_CLEANUP === "1";

  // Parse --port-offset <N> flag and propagate via env var
  const portOffsetIdx = process.argv.indexOf("--port-offset");
  const portOffset = portOffsetIdx !== -1 ? parseInt(process.argv[portOffsetIdx + 1], 10) : 0;
  if (portOffset) {
    process.env.ANVIL_INTEROP_PORT_OFFSET = portOffset.toString();
  }

  // Set env for genesis upgrade deployer
  process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE = process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE || "1";

  try {
    if (!skipSetup) {
      // Cleanup previous state (still uses shell script for process killing)
      timedRun("cleanup", "yarn", ["cleanup"], anvilInteropDir);

      const runner = new DeploymentRunner();
      const anvilManager = new AnvilManager();
      const config = runner.getConfig();

      let chains: Awaited<ReturnType<typeof runner.runFullDeployment>>["chains"];
      let l1Addresses: Awaited<ReturnType<typeof runner.runFullDeployment>>["l1Addresses"];
      let ctmAddresses: Awaited<ReturnType<typeof runner.runFullDeployment>>["ctmAddresses"];

      // Try loading pre-generated chain states (much faster — skips deploy steps 2-5)
      // Set ANVIL_INTEROP_FRESH_DEPLOY=1 to force full deployment instead.
      const freshDeploy = process.env.ANVIL_INTEROP_FRESH_DEPLOY === "1";
      if (!freshDeploy && runner.hasChainStates()) {
        const stateDir = runner.getChainStatesDir();
        console.log(`\nFound pre-generated chain states at ${stateDir}`);
        const result = await timedAsync("load chain states", () => runner.loadChainStates(anvilManager, stateDir));
        chains = result.chains;
        l1Addresses = result.l1Addresses;
        ctmAddresses = result.ctmAddresses;
      } else {
        console.log("\nNo pre-generated chain states found, running full deployment...");
        const result = await timedAsync("full deployment (steps 1-5)", () => runner.runFullDeployment(anvilManager));
        chains = result.chains;
        l1Addresses = result.l1Addresses;
        ctmAddresses = result.ctmAddresses;
      }

      if (!chains.l1) {
        throw new Error("L1 chain not found");
      }

      const gatewayConfig = config.chains.find((c) => c.isGateway);
      const gatewayChainId = gatewayConfig?.chainId;
      const gwChain = chains.l2.find((c) => c.chainId === gatewayChainId);
      const gwSettledChainIds = getGwSettledChainIds(config.chains);

      // Build L2 chain RPC URL map for migration preconditions
      const l2ChainRpcUrls = new Map<number, string>();
      for (const l2Chain of chains.l2) {
        l2ChainRpcUrls.set(l2Chain.chainId, l2Chain.rpcUrl);
      }

      // Deploy test tokens if not already present in the preloaded state.
      // When state was generated with setup-and-dump-state.ts, tokens are included in the dump.
      const preloadedState = runner.loadState();
      const hasTestTokens = preloadedState.testTokens && Object.keys(preloadedState.testTokens).length > 0;
      if (!hasTestTokens) {
        await timedAsync("deploy:test-token", () => deployTestTokens());
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
      "hardhat test - all interop specs",
      "yarn",
      [
        "hardhat",
        "test",
        "test/anvil-interop/test/hardhat/01-deployment-verification.spec.ts",
        "test/anvil-interop/test/hardhat/02-direct-bridge.spec.ts",
        "test/anvil-interop/test/hardhat/03-interop-transfer.spec.ts",
        "test/anvil-interop/test/hardhat/04-gateway-setup.spec.ts",
        "test/anvil-interop/test/hardhat/05-gateway-bridge.spec.ts",
        "test/anvil-interop/test/hardhat/06-gateway-interop.spec.ts",
        "--network",
        "hardhat",
        "--no-compile",
      ],
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
