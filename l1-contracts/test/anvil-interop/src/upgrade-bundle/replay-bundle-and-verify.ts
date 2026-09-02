import type { ChildProcess } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import {
  ANVIL_GAS_PRICE_WEI,
  DEFAULT_GATEWAY_RPC_URL,
  DEFAULT_ZK_GOVERNANCE_COMMIT,
  REPLAY_PORT_OFFSET,
  SIGINT_EXIT_CODE,
  SIGTERM_EXIT_CODE,
  V31_UPGRADE_NAME,
} from "./constants";
import {
  L1_CONTRACTS_DIR,
  REPO_ROOT,
  envAnvilPort,
  envHasGateway,
  fileSha256,
  fundBundleTargets,
  isRpcReady,
  locateProtocolOps,
  readToml,
  requireFile,
  requireTomlString,
  runCli,
  startAnvilFork,
  stopAnvil,
  verifyBundleIntegrity,
  writeCombinedLog,
} from "./common";
import { broadcastUpgrade, verifyUpgrade } from "./operations";

interface ReplayArguments {
  bundleDirectory: string;
  forkUrl?: string;
  rpcUrl?: string;
  deployerKey?: string;
  verifyOnly: boolean;
}

function usage(): never {
  throw new Error(
    "usage: yarn bundle:replay --bundle <dir> (--fork-url <l1-rpc> | --rpc <rpc>) " + "[--key <0xhex>] [--verify-only]"
  );
}

function parseArguments(args: string[]): ReplayArguments {
  let bundleDirectory: string | undefined;
  let forkUrl: string | undefined;
  let rpcUrl: string | undefined;
  let deployerKey: string | undefined;
  let verifyOnly = false;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    const value = (): string => {
      const next = args[index + 1];
      if (!next) usage();
      index += 1;
      return next;
    };
    if (argument === "--bundle") bundleDirectory = value();
    else if (argument === "--fork-url") forkUrl = value();
    else if (argument === "--rpc") rpcUrl = value();
    else if (argument === "--key") deployerKey = value();
    else if (argument === "--verify-only") verifyOnly = true;
    else usage();
  }
  if (!bundleDirectory || (!forkUrl && !rpcUrl) || (forkUrl && rpcUrl)) usage();
  return { bundleDirectory: path.resolve(bundleDirectory), forkUrl, rpcUrl, deployerKey, verifyOnly };
}

async function replayBundleAndVerify(args: ReplayArguments): Promise<void> {
  requireFile(path.join(args.bundleDirectory, "bundle-metadata.json"), "deploy bundle metadata");
  const metadata = verifyBundleIntegrity(args.bundleDirectory);
  const environment = metadata.env;
  const deployer = metadata.deployer_address;
  if (!deployer) throw new Error("bundle metadata has no deployer_address");
  const permanentValuesPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs/permanent-values", `${environment}.toml`);
  const v31InputPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, `${environment}.toml`);
  requireFile(permanentValuesPath, `config for env '${environment}'`);
  requireFile(v31InputPath, `config for env '${environment}'`);

  console.log(`Env:          ${environment}`);
  console.log(`Bundle:       ${args.bundleDirectory}`);
  console.log(`Deployer:     ${deployer}`);

  const localHashesSha = fileSha256(path.join(REPO_ROOT, "AllContractsHashes.json"));
  if (!metadata.all_contracts_hashes_sha256) throw new Error("bundle metadata has no all_contracts_hashes_sha256");
  if (localHashesSha !== metadata.all_contracts_hashes_sha256) {
    throw new Error(
      "AllContractsHashes.json differs from the bundle's.\n" +
        `  bundle: ${metadata.all_contracts_hashes_sha256} (commit ${metadata.contracts_commit})\n` +
        `  local:  ${localHashesSha}\n` +
        `PUVT will not recognise the deployed bytecode. Check out ${metadata.contracts_commit} first.`
    );
  }

  const protocolOps = locateProtocolOps();
  console.log(`protocol_ops: ${protocolOps}`);
  const workDirectory = path.join(args.bundleDirectory, "replay");
  fs.mkdirSync(workDirectory, { recursive: true });
  let rpcUrl = args.rpcUrl;
  let anvil: ChildProcess | undefined;
  const keepAnvil = process.env.KEEP_ANVIL === "1";
  const cleanup = async (): Promise<void> => {
    if (!anvil) return;
    if (keepAnvil) {
      console.log(`Leaving anvil (pid ${anvil.pid}) running on ${rpcUrl} (KEEP_ANVIL=1)`);
      return;
    }
    console.log(`Stopping anvil (pid ${anvil.pid})...`);
    await stopAnvil(anvil);
    anvil = undefined;
  };
  const interruptHandler = (): void => {
    void cleanup().finally(() => process.exit(SIGINT_EXIT_CODE));
  };
  const terminateHandler = (): void => {
    void cleanup().finally(() => process.exit(SIGTERM_EXIT_CODE));
  };
  process.once("SIGINT", interruptHandler);
  process.once("SIGTERM", terminateHandler);

  try {
    if (args.forkUrl) {
      const port = envAnvilPort(environment) + REPLAY_PORT_OFFSET;
      rpcUrl = `http://localhost:${port}`;
      if (await isRpcReady(rpcUrl)) {
        console.log(`=== Step 0: reusing anvil on ${rpcUrl} ===`);
      } else {
        console.log(`=== Step 0: anvil fork on port ${port} ===`);
        if (metadata.l1.forked_at_block === null) {
          console.warn(
            "WARNING: the bundle records no fork height — forking at chain tip. " +
              "If the upgrade is live, re-pack with FORKED_AT_BLOCK or pass --rpc."
          );
        }
        anvil = await startAnvilFork({
          port,
          forkUrl: args.forkUrl,
          forkBlock: metadata.l1.forked_at_block ?? undefined,
          logPath: path.join(workDirectory, "anvil.log"),
        });
      }
    }
    if (!rpcUrl) usage();
    console.log(`L1 RPC:       ${rpcUrl}`);
    const gatewayRpcUrl = process.env.GW_RPC_URL ?? DEFAULT_GATEWAY_RPC_URL;
    console.log(`GW RPC:       ${gatewayRpcUrl}`);

    const manifestPath = path.join(args.bundleDirectory, "prepare/manifest.json");
    const executedPath = path.join(workDirectory, "executed.json");
    const transactionsPath = path.join(workDirectory, "transactions.txt");
    if (args.verifyOnly) {
      console.log("=== Steps 1-2: SKIPPED (--verify-only) ===");
    } else {
      if (args.forkUrl) {
        console.log("=== Step 1: fund every bundle signer (fork only) ===");
        const v31Input = readToml(v31InputPath);
        const permanentValues = readToml(permanentValuesPath);
        await fundBundleTargets({
          rpcUrl,
          bridgehub: requireTomlString(v31Input, "bridgehub_proxy_address", v31InputPath),
          zkAssetId: requireTomlString(permanentValues, "zk_token_asset_id", permanentValuesPath),
          hasGateway: envHasGateway(permanentValues),
          manifestPath,
          ecosystemTomlPath: path.join(args.bundleDirectory, "ecosystem.toml"),
          deployer,
        });
        const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
        await provider.send("anvil_setNextBlockBaseFeePerGas", [`0x${ANVIL_GAS_PRICE_WEI.toString(16)}`]);
      }
      console.log("=== Step 2: upgrade-broadcast ===");
      await broadcastUpgrade({
        protocolOps,
        manifestPath,
        rpcUrl,
        outputPath: executedPath,
        deployer,
        privateKey: args.deployerKey,
      });
    }

    console.log("=== Step 3: verify-upgrade (PUVT) ===");
    const combinedTransactionsPath = path.join(workDirectory, "transactions.combined.txt");
    const realTransactionsPath = path.join(
      L1_CONTRACTS_DIR,
      "upgrade-envs",
      V31_UPGRADE_NAME,
      "output",
      environment,
      "transactions.txt"
    );
    writeCombinedLog(combinedTransactionsPath, [realTransactionsPath, transactionsPath]);
    await verifyUpgrade({
      protocolOps,
      environment,
      ecosystemTomlPath: path.join(args.bundleDirectory, "ecosystem.toml"),
      rpcUrl,
      gatewayRpcUrl,
      transactionsLogPath: combinedTransactionsPath,
      zkGovernanceCommit:
        process.env.ZK_GOVERNANCE_COMMIT ?? metadata.zk_governance_commit ?? DEFAULT_ZK_GOVERNANCE_COMMIT,
    });
    console.log("=== Done ===");
  } finally {
    process.removeListener("SIGINT", interruptHandler);
    process.removeListener("SIGTERM", terminateHandler);
    await cleanup();
  }
}

runCli(() => replayBundleAndVerify(parseArguments(process.argv.slice(2))));
