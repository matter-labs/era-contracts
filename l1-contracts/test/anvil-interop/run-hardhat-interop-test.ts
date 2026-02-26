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

  // Set env for genesis upgrade deployer
  process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE = process.env.ANVIL_INTEROP_USE_L2_GENESIS_UPGRADE || "1";

  try {
    if (!skipSetup) {
      // Cleanup previous state (still uses shell script for process killing)
      timedRun("cleanup", "yarn", ["cleanup"], anvilInteropDir);

      const runner = new DeploymentRunner();
      const anvilManager = new AnvilManager();
      const config = runner.getConfig();

      // Step 1: Start Anvil chains
      const { chains } = await timedAsync("step1 - Start Anvil chains", () =>
        runner.step1StartChains(anvilManager)
      );

      if (!chains.l1) {
        throw new Error("L1 chain not found");
      }

      // Step 2: Deploy L1 contracts
      const { l1Addresses, ctmAddresses } = await timedAsync("step2 - Deploy L1 contracts", () =>
        runner.step2DeployL1(chains.l1!.rpcUrl)
      );

      // Step 3+4: Register L2 chains and initialize (pipelined)
      await timedAsync("step3+4 - Register & init L2 chains", () =>
        runner.step3And4RegisterAndInitChains(
          chains.l1!.rpcUrl,
          chains.l2,
          chains.config,
          l1Addresses,
          ctmAddresses
        )
      );

      // Step 5 + deploy:test-token in parallel (both independent after step 4)
      const gatewayConfig = config.chains.find((c) => c.isGateway);
      const gatewayChainId = gatewayConfig?.chainId;
      const gwChain = chains.l2.find((c) => c.chainId === gatewayChainId);

      // Build L2 chain RPC URL map for migration preconditions
      const l2ChainRpcUrls = new Map<number, string>();
      for (const l2Chain of chains.l2) {
        l2ChainRpcUrls.set(l2Chain.chainId, l2Chain.rpcUrl);
      }

      const gwSettledChainIds = getGwSettledChainIds(config.chains);

      await timedAsync("step5 + deploy:test-token (parallel)", () =>
        Promise.all([
          gatewayChainId
            ? runner.step5SetupGateway(
                chains.l1!.rpcUrl,
                gatewayChainId,
                l1Addresses,
                ctmAddresses,
                gwChain?.rpcUrl,
                gwSettledChainIds,
                l2ChainRpcUrls
              )
            : Promise.resolve(),
          deployTestTokens(),
        ])
      );

      // Run Token Balance Migration (TBM) for test tokens on GW-settled chains.
      // Test tokens are native to their respective L2 chains. After gateway migration,
      // outgoing transfers from GW-settled chains require assetMigrationNumber == migrationNumber.
      // The real TBM flow (L2→L1→GW+L2 confirmations) properly sets assetMigrationNumber.
      if (gwSettledChainIds.length > 0 && gwChain?.rpcUrl) {
        const freshState = runner.loadState();
        if (freshState.testTokens && Object.keys(freshState.testTokens).length > 0) {
          const gwDiamondProxy = freshState.chainAddresses!.find(
            (c) => c.chainId === gatewayChainId
          )!.diamondProxy;

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
