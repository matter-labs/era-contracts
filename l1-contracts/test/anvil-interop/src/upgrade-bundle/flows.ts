import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { bundleProvenanceFromEnvironment, packDeployBundle, verifyBundleIntegrity } from "./bundle";
import {
  DEFAULT_GATEWAY_RPC_URL,
  DEFAULT_ZK_GOVERNANCE_COMMIT,
  L1_CONTRACTS_DIR,
  REPLAY_PORT_OFFSET,
  REPO_ROOT,
  V31_UPGRADE_NAME,
  anvilPort,
  fileSha256,
  loadUpgradeEnvironment,
  parseInteger,
  parseUpgradeEnvironment,
  requireFile,
  writeCombinedLog,
} from "./common";
import { AnvilFork, ProtocolOps, fundBundleTargets } from "./fork";

// ─── Regenerate ──────────────────────────────────────────────────────────────────

function environmentFlag(name: string): boolean {
  return process.env[name] === "1";
}

function resolveDeployer(): string {
  if (process.env.DEPLOYER_ADDR) return ethers.utils.getAddress(process.env.DEPLOYER_ADDR);
  let privateKey = process.env.DEPLOYER_PK;
  if (!privateKey && process.env.DEPLOYER_PK_FILE) {
    requireFile(process.env.DEPLOYER_PK_FILE, "DEPLOYER_PK_FILE");
    privateKey = fs.readFileSync(process.env.DEPLOYER_PK_FILE, "utf8").replace(/\s/g, "");
  }
  if (!privateKey) {
    throw new Error("Set DEPLOYER_ADDR, DEPLOYER_PK, or DEPLOYER_PK_FILE before running");
  }
  try {
    return new ethers.Wallet(privateKey).address;
  } catch {
    throw new Error("The configured deployer private key is invalid");
  }
}

export async function regenerateAndVerify(environment: string): Promise<void> {
  const forkUrl = process.env.L1_FORK_URL;
  if (!forkUrl) throw new Error("L1_FORK_URL is required");
  const environmentName = parseUpgradeEnvironment(environment);
  const config = loadUpgradeEnvironment(environmentName);
  const port = anvilPort(environmentName);
  console.log(`Env:          ${environmentName} (anvil port ${port})`);
  const deployer = resolveDeployer();
  const gatewayRpcUrl = process.env.GW_RPC_URL ?? DEFAULT_GATEWAY_RPC_URL;
  const zkGovernanceCommit = process.env.ZK_GOVERNANCE_COMMIT ?? DEFAULT_ZK_GOVERNANCE_COMMIT;
  console.log(`Bridgehub:    ${config.bridgehubAddress}`);
  console.log(`Deployer EOA: ${deployer}`);
  console.log(`ZK asset id:  ${config.zkAssetId}`);
  console.log(`New gateway:  ${config.hasGateway ? "yes" : "no (ZK funding best-effort)"}`);
  console.log(`GW RPC:       ${gatewayRpcUrl}`);
  console.log(`zk-gov commit: ${zkGovernanceCommit}`);
  const protocolOps = new ProtocolOps();
  console.log(`Using protocol_ops at: ${protocolOps.executable}`);

  const skipPrepare = environmentFlag("SKIP_PREPARE");
  if (!skipPrepare) {
    const transactionsPath = path.join(config.outputDirectory, "transactions.txt");
    const transactions = fs.existsSync(transactionsPath) ? fs.readFileSync(transactionsPath) : undefined;
    fs.rmSync(config.outputDirectory, { recursive: true, force: true });
    fs.mkdirSync(config.outputDirectory, { recursive: true });
    if (transactions) fs.writeFileSync(transactionsPath, transactions);
  } else {
    fs.mkdirSync(config.outputDirectory, { recursive: true });
  }

  const anvil = await AnvilFork.connectOrStart({
    port,
    forkUrl,
    forkBlock: parseInteger(process.env.FORK_BLOCK, "FORK_BLOCK"),
    logPath: path.join(config.outputDirectory, "anvil.log"),
  });
  await anvil.run(environmentFlag("KEEP_ANVIL"), async ({ provider, rpcUrl }) => {
    const forkedAtBlock = await provider.getBlockNumber();
    console.log(`Forked at block: ${forkedAtBlock}`);

    const prepareDirectory = path.join(config.outputDirectory, "prepare");
    const manifestPath = path.join(prepareDirectory, "manifest.json");
    if (skipPrepare && fs.existsSync(manifestPath)) {
      console.log(`=== Step 1: SKIPPED (SKIP_PREPARE=1, reusing existing ${prepareDirectory}) ===`);
    } else {
      console.log("=== Step 1: upgrade-prepare-all (this takes ~12 min) ===");
      await protocolOps.prepare({
        environment: environmentName,
        bridgehub: config.bridgehubAddress,
        rpcUrl,
        deployer,
        outputDirectory: prepareDirectory,
      });
    }

    console.log("=== Step 1b: pack the deploy bundle ===");
    packDeployBundle(environmentName, {
      provenance: bundleProvenanceFromEnvironment({
        deployerAddress: deployer,
        forkedAtBlock,
        zkGovernanceCommit,
      }),
    });

    const forkDirectory = path.join(config.outputDirectory, "fork-rehearsal");
    const forkTransactionsPath = path.join(forkDirectory, "transactions.txt");
    const combinedTransactionsPath = path.join(forkDirectory, "transactions.combined.txt");
    const realTransactionsPath = path.join(config.outputDirectory, "transactions.txt");
    if (environmentFlag("SKIP_BROADCAST") && fs.existsSync(path.join(forkDirectory, "executed.json"))) {
      console.log(`=== Steps 2-3: SKIPPED (SKIP_BROADCAST=1, reusing ${forkDirectory}/executed.json) ===`);
      console.log("=== Step 4: verify-upgrade (PUVT) ===");
      writeCombinedLog(combinedTransactionsPath, [realTransactionsPath, forkTransactionsPath]);
      await protocolOps.verify({
        environment: environmentName,
        ecosystemTomlPath: path.join(config.outputDirectory, "ecosystem.toml"),
        rpcUrl,
        gatewayRpcUrl,
        transactionsLogPath: combinedTransactionsPath,
        zkGovernanceCommit,
      });
      console.log("=== Done ===");
      return;
    }

    console.log("=== Step 2: resolve NTV + ZK token, fund every bundle target ===");
    await fundBundleTargets(provider, {
      bridgehubAddress: config.bridgehubAddress,
      zkAssetId: config.zkAssetId,
      hasGateway: config.hasGateway,
      manifestPath,
      ecosystemTomlPath: path.join(config.outputDirectory, "ecosystem.toml"),
      deployerAddress: deployer,
    });

    console.log("=== Step 3: upgrade-broadcast --unlocked --out ===");
    fs.rmSync(forkDirectory, { recursive: true, force: true });
    fs.mkdirSync(forkDirectory, { recursive: true });
    await anvil.setNextBlockBaseFee();
    await protocolOps.broadcast({
      manifestPath,
      rpcUrl,
      outputPath: path.join(forkDirectory, "executed.json"),
    });

    console.log("=== Step 4: verify-upgrade (PUVT) ===");
    writeCombinedLog(combinedTransactionsPath, [realTransactionsPath, forkTransactionsPath]);
    await protocolOps.verify({
      environment: environmentName,
      ecosystemTomlPath: path.join(config.outputDirectory, "ecosystem.toml"),
      rpcUrl,
      gatewayRpcUrl,
      transactionsLogPath: combinedTransactionsPath,
      zkGovernanceCommit,
    });
    console.log("=== Done ===");
  });
}

// ─── Replay ──────────────────────────────────────────────────────────────────────

export interface ReplayOptions {
  bundleDirectory: string;
  forkUrl?: string;
  rpcUrl?: string;
  deployerKey?: string;
  verifyOnly: boolean;
}

export async function replayBundleAndVerify(args: ReplayOptions): Promise<void> {
  if (Boolean(args.forkUrl) === Boolean(args.rpcUrl)) {
    throw new Error("replay requires exactly one of forkUrl or rpcUrl");
  }
  requireFile(path.join(args.bundleDirectory, "bundle-metadata.json"), "deploy bundle metadata");
  const metadata = verifyBundleIntegrity(args.bundleDirectory);
  const environment = parseUpgradeEnvironment(metadata.env);
  const deployer = metadata.deployer_address ? ethers.utils.getAddress(metadata.deployer_address) : undefined;
  if (!deployer) throw new Error("bundle metadata has no deployer_address");
  if (args.deployerKey) {
    let signerAddress: string;
    try {
      signerAddress = new ethers.Wallet(args.deployerKey).address;
    } catch {
      throw new Error("the supplied private key is invalid");
    }
    if (signerAddress !== deployer) {
      throw new Error("the supplied private key does not match the bundle deployer");
    }
  }
  const config = loadUpgradeEnvironment(environment);

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

  const protocolOps = new ProtocolOps();
  console.log(`protocol_ops: ${protocolOps.executable}`);
  const workDirectory = path.join(args.bundleDirectory, "replay");
  fs.mkdirSync(workDirectory, { recursive: true });
  if (args.forkUrl && metadata.l1.forked_at_block === null) {
    console.warn(
      "WARNING: the bundle records no fork height — forking at chain tip. " +
        "If the upgrade is live, re-pack with FORKED_AT_BLOCK or pass --rpc."
    );
  }
  const replay = async (
    provider: ethers.providers.JsonRpcProvider,
    rpcUrl: string,
    setNextBlockBaseFee?: () => Promise<void>
  ): Promise<void> => {
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
        await fundBundleTargets(provider, {
          bridgehubAddress: config.bridgehubAddress,
          zkAssetId: config.zkAssetId,
          hasGateway: config.hasGateway,
          manifestPath,
          ecosystemTomlPath: path.join(args.bundleDirectory, "ecosystem.toml"),
          deployerAddress: deployer,
        });
        if (!setNextBlockBaseFee) throw new Error("fork replay requires Anvil RPC controls");
        await setNextBlockBaseFee();
      }
      console.log("=== Step 2: upgrade-broadcast ===");
      await protocolOps.broadcast({
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
    await protocolOps.verify({
      environment,
      ecosystemTomlPath: path.join(args.bundleDirectory, "ecosystem.toml"),
      rpcUrl,
      gatewayRpcUrl,
      transactionsLogPath: combinedTransactionsPath,
      zkGovernanceCommit:
        process.env.ZK_GOVERNANCE_COMMIT ?? metadata.zk_governance_commit ?? DEFAULT_ZK_GOVERNANCE_COMMIT,
    });
    console.log("=== Done ===");
  };

  if (args.forkUrl) {
    const anvil = await AnvilFork.connectOrStart({
      port: anvilPort(environment) + REPLAY_PORT_OFFSET,
      forkUrl: args.forkUrl,
      forkBlock: metadata.l1.forked_at_block ?? undefined,
      logPath: path.join(workDirectory, "anvil.log"),
    });
    await anvil.run(process.env.KEEP_ANVIL === "1", ({ provider, rpcUrl }) =>
      replay(provider, rpcUrl, () => anvil.setNextBlockBaseFee())
    );
  } else if (args.rpcUrl) {
    await replay(new ethers.providers.JsonRpcProvider(args.rpcUrl), args.rpcUrl);
  }
}
