import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { packDeployBundle, verifyBundleIntegrity } from "./bundle";
import {
  BUNDLE_METADATA_FILE,
  DEFAULT_GATEWAY_RPC_URL,
  DEFAULT_ZK_GOVERNANCE_COMMIT,
  REPLAY_PORT_OFFSET,
  REPO_ROOT,
  TRANSACTIONS_LOG,
  anvilPort,
  fileSha256,
  loadUpgradeEnvironment,
  parseUpgradeEnvironment,
  requireFile,
  writeCombinedLog,
} from "./common";
import type { UpgradeEnvironment } from "./common";
import { ProtocolOps, fundBundleTargets, withAnvilFork } from "./fork";
import type { AnvilFork } from "./fork";

/** PUVT inputs shared by both flows. */
export interface VerifySettings {
  gatewayRpcUrl: string;
  zkGovernanceCommit: string;
}

interface BundlePaths {
  manifestPath: string;
  ecosystemTomlPath: string;
  /** Where this run's `executed.json`, transaction log and anvil log go. */
  workDirectory: string;
}

function step(title: string): void {
  console.log(`=== ${title} ===`);
}

/** Wipe a previous run's output, keeping only the committed real-network transaction log. */
function resetOutputDirectory(directory: string): void {
  fs.mkdirSync(directory, { recursive: true });
  for (const entry of fs.readdirSync(directory)) {
    if (entry !== TRANSACTIONS_LOG) fs.rmSync(path.join(directory, entry), { recursive: true, force: true });
  }
}

/** Fund every signer on the fork, then replay the whole manifest under impersonation. */
async function rehearseBroadcast(
  anvil: AnvilFork,
  protocolOps: ProtocolOps,
  environment: UpgradeEnvironment,
  deployer: string,
  paths: BundlePaths
): Promise<void> {
  step("fund every bundle signer");
  await fundBundleTargets(anvil.provider, {
    environment,
    manifestPath: paths.manifestPath,
    ecosystemTomlPath: paths.ecosystemTomlPath,
    deployerAddress: deployer,
  });
  step("upgrade-broadcast (impersonated)");
  fs.mkdirSync(paths.workDirectory, { recursive: true });
  await anvil.setNextBlockBaseFee();
  await protocolOps.broadcast({
    manifestPath: paths.manifestPath,
    rpcUrl: anvil.rpcUrl,
    outputPath: path.join(paths.workDirectory, "executed.json"),
  });
}

/**
 * Run PUVT against `rpcUrl`. It resolves CREATE2 deployments from transaction hashes,
 * so the committed real-network log and this run's own log are fed to it together.
 */
async function verifyUpgrade(
  protocolOps: ProtocolOps,
  environment: UpgradeEnvironment,
  settings: VerifySettings,
  rpcUrl: string,
  paths: BundlePaths
): Promise<void> {
  step("verify-upgrade (PUVT)");
  const combinedLog = path.join(paths.workDirectory, "transactions.combined.txt");
  writeCombinedLog(combinedLog, [
    path.join(environment.outputDirectory, TRANSACTIONS_LOG),
    path.join(paths.workDirectory, TRANSACTIONS_LOG),
  ]);
  await protocolOps.verify({
    environment: environment.name,
    ecosystemTomlPath: paths.ecosystemTomlPath,
    rpcUrl,
    gatewayRpcUrl: settings.gatewayRpcUrl,
    transactionsLogPath: combinedLog,
    zkGovernanceCommit: settings.zkGovernanceCommit,
  });
}

// ─── Regenerate ──────────────────────────────────────────────────────────────────

export interface RegenerateOptions extends VerifySettings {
  environment: string;
  forkUrl: string;
  /** The EOA whose bundles are the deployer's: impersonated on the fork and baked into some init code. */
  deployer: string;
  /** Pin the fork to this L1 height; defaults to the chain tip. */
  forkBlock?: number;
  foundryZksyncVersion?: string;
}

/** Fork L1, prepare the upgrade, pack the deploy bundle, replay it and run PUVT. */
export async function regenerateAndVerify(options: RegenerateOptions): Promise<void> {
  const environment = loadUpgradeEnvironment(parseUpgradeEnvironment(options.environment));
  const deployer = ethers.utils.getAddress(options.deployer);
  const protocolOps = new ProtocolOps();
  console.log(
    `Env: ${environment.name} (bridgehub ${environment.bridgehubAddress}, gateway: ${environment.hasGateway ? "yes" : "no"})`
  );
  console.log(`Deployer: ${deployer} (impersonated)`);
  console.log(`protocol_ops: ${protocolOps.executable}`);

  resetOutputDirectory(environment.outputDirectory);
  const prepareDirectory = path.join(environment.outputDirectory, "prepare");
  const paths: BundlePaths = {
    manifestPath: path.join(prepareDirectory, "manifest.json"),
    ecosystemTomlPath: path.join(environment.outputDirectory, "ecosystem.toml"),
    workDirectory: path.join(environment.outputDirectory, "fork-rehearsal"),
  };

  await withAnvilFork(
    {
      port: anvilPort(environment.name),
      forkUrl: options.forkUrl,
      forkBlock: options.forkBlock,
      logPath: path.join(environment.outputDirectory, "anvil.log"),
    },
    async (anvil) => {
      console.log(`Forked L1 at block ${anvil.forkedAtBlock} on ${anvil.rpcUrl}`);
      step("upgrade-prepare-all (this takes ~12 min)");
      await protocolOps.prepare({
        environment: environment.name,
        bridgehub: environment.bridgehubAddress,
        rpcUrl: anvil.rpcUrl,
        deployer,
        outputDirectory: prepareDirectory,
      });

      step("pack the deploy bundle");
      packDeployBundle(environment.name, {
        provenance: {
          deployerAddress: deployer,
          forkedAtBlock: anvil.forkedAtBlock,
          zkGovernanceCommit: options.zkGovernanceCommit,
          foundryZksyncVersion: options.foundryZksyncVersion,
        },
      });

      await rehearseBroadcast(anvil, protocolOps, environment, deployer, paths);
      await verifyUpgrade(protocolOps, environment, options, anvil.rpcUrl, paths);
    }
  );
  step("Done");
}

// ─── Replay ──────────────────────────────────────────────────────────────────────

/** How a deploy bundle is consumed. */
export type ReplayMode =
  /** Fork L1 at the bundle's recorded height and replay every bundle under impersonation. */
  | { kind: "rehearse"; forkUrl: string }
  /** Sign and broadcast the deployer's bundles for real; the governance bundles are skipped. */
  | { kind: "broadcast"; rpcUrl: string; deployerKey: string }
  /** Only run PUVT against a chain the bundle was already broadcast to. */
  | { kind: "verify"; rpcUrl: string };

export interface ReplayOptions extends Partial<VerifySettings> {
  bundleDirectory: string;
  mode: ReplayMode;
}

function signerAddress(privateKey: string): string {
  try {
    return new ethers.Wallet(privateKey).address;
  } catch {
    throw new Error("the supplied private key is invalid");
  }
}

export async function replayBundleAndVerify(options: ReplayOptions): Promise<void> {
  requireFile(path.join(options.bundleDirectory, BUNDLE_METADATA_FILE), "deploy bundle metadata");
  const metadata = verifyBundleIntegrity(options.bundleDirectory);
  const environment = loadUpgradeEnvironment(parseUpgradeEnvironment(metadata.env));
  if (!metadata.deployer_address) throw new Error("bundle metadata has no deployer_address");
  const deployer = ethers.utils.getAddress(metadata.deployer_address);
  const { mode } = options;
  if (mode.kind === "broadcast" && signerAddress(mode.deployerKey) !== deployer) {
    throw new Error("the supplied private key does not match the bundle deployer");
  }

  // PUVT recognises deployed code through the checkout's AllContractsHashes.json.
  const localHashes = fileSha256(path.join(REPO_ROOT, "AllContractsHashes.json"));
  if (localHashes !== metadata.all_contracts_hashes_sha256) {
    throw new Error(
      "AllContractsHashes.json differs from the bundle's.\n" +
        `  bundle: ${metadata.all_contracts_hashes_sha256} (commit ${metadata.contracts_commit})\n` +
        `  local:  ${localHashes}\n` +
        `PUVT will not recognise the deployed bytecode. Check out ${metadata.contracts_commit} first.`
    );
  }

  const settings: VerifySettings = {
    gatewayRpcUrl: options.gatewayRpcUrl ?? DEFAULT_GATEWAY_RPC_URL,
    zkGovernanceCommit: options.zkGovernanceCommit ?? metadata.zk_governance_commit ?? DEFAULT_ZK_GOVERNANCE_COMMIT,
  };
  const protocolOps = new ProtocolOps();
  // Replay state goes next to the env's other outputs, never into the bundle (the handoff artifact).
  const paths: BundlePaths = {
    manifestPath: path.join(options.bundleDirectory, "prepare/manifest.json"),
    ecosystemTomlPath: path.join(options.bundleDirectory, "ecosystem.toml"),
    workDirectory: path.join(environment.outputDirectory, "replay"),
  };
  fs.mkdirSync(paths.workDirectory, { recursive: true });
  console.log(`Env: ${environment.name} | bundle: ${options.bundleDirectory} | deployer: ${deployer}`);
  console.log(`protocol_ops: ${protocolOps.executable}`);

  switch (mode.kind) {
    case "rehearse":
      if (metadata.l1.forked_at_block === null) {
        console.warn(
          "WARNING: the bundle records no fork height; forking at the chain tip, which reverts if the upgrade is live."
        );
      }
      await withAnvilFork(
        {
          port: anvilPort(environment.name) + REPLAY_PORT_OFFSET,
          forkUrl: mode.forkUrl,
          forkBlock: metadata.l1.forked_at_block ?? undefined,
          logPath: path.join(paths.workDirectory, "anvil.log"),
        },
        async (anvil) => {
          await rehearseBroadcast(anvil, protocolOps, environment, deployer, paths);
          await verifyUpgrade(protocolOps, environment, settings, anvil.rpcUrl, paths);
        }
      );
      break;
    case "broadcast":
      step("upgrade-broadcast (signing the deployer's bundles)");
      await protocolOps.broadcast({
        manifestPath: paths.manifestPath,
        rpcUrl: mode.rpcUrl,
        outputPath: path.join(paths.workDirectory, "executed.json"),
        deployer,
        privateKey: mode.deployerKey,
      });
      await verifyUpgrade(protocolOps, environment, settings, mode.rpcUrl, paths);
      break;
    case "verify":
      await verifyUpgrade(protocolOps, environment, settings, mode.rpcUrl, paths);
      break;
  }
  step("Done");
}
