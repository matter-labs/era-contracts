import { spawn } from "child_process";
import type { ChildProcess } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import {
  ANVIL_BALANCE,
  ANVIL_GAS_PRICE,
  ANVIL_READY_ATTEMPTS,
  ANVIL_READY_DELAY_MS,
  ANVIL_STOP_TIMEOUT_MS,
  BUNDLE_TARGET_TOKEN_FUNDING,
  PROTOCOL_OPS_MEMORY_LIMIT,
  bundleManifestSchema,
  ecosystemTomlSchema,
  locateProtocolOps,
  readJsonAs,
  readTomlAs,
  runCommand,
} from "./common";
import type { UpgradeEnvironment } from "./common";

// ─── Anvil fork ──────────────────────────────────────────────────────────────────

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function isServing(provider: ethers.providers.JsonRpcProvider): Promise<boolean> {
  try {
    await provider.send("eth_chainId", []);
    return true;
  } catch {
    return false;
  }
}

export interface AnvilForkOptions {
  port: number;
  forkUrl: string;
  /** Pin the fork to this L1 height; defaults to the chain tip. */
  forkBlock?: number;
  logPath: string;
}

/** A local anvil fork of L1 with every account impersonatable. */
export class AnvilFork {
  public readonly rpcUrl: string;
  public readonly provider: ethers.providers.JsonRpcProvider;
  /** The L1 height the fork was taken at. */
  public readonly forkedAtBlock: number;
  private readonly child: ChildProcess;

  private constructor(rpcUrl: string, forkedAtBlock: number, child: ChildProcess) {
    this.rpcUrl = rpcUrl;
    this.provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    this.forkedAtBlock = forkedAtBlock;
    this.child = child;
  }

  public static async start(options: AnvilForkOptions): Promise<AnvilFork> {
    const rpcUrl = `http://localhost:${options.port}`;
    const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    if (await isServing(provider)) {
      throw new Error(`something is already listening on ${rpcUrl}; stop it before starting a fork on that port`);
    }

    const args = [
      "--port",
      String(options.port),
      "--auto-impersonate",
      "--disable-block-gas-limit",
      "--gas-price",
      ANVIL_GAS_PRICE.toString(),
      "--fork-url",
      options.forkUrl,
    ];
    if (options.forkBlock !== undefined) args.push("--fork-block-number", String(options.forkBlock));

    fs.mkdirSync(path.dirname(options.logPath), { recursive: true });
    const log = fs.openSync(options.logPath, "w");
    const child = spawn("anvil", args, { stdio: ["ignore", log, log] });
    fs.closeSync(log);
    await new Promise<void>((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", reject);
    });

    for (let attempt = 0; attempt < ANVIL_READY_ATTEMPTS; attempt += 1) {
      if (await isServing(provider)) return new AnvilFork(rpcUrl, await provider.getBlockNumber(), child);
      if (child.exitCode !== null) {
        throw new Error(`anvil exited with code ${child.exitCode} before becoming ready (see ${options.logPath})`);
      }
      await delay(ANVIL_READY_DELAY_MS);
    }
    child.kill("SIGKILL");
    throw new Error(`anvil failed to start (see ${options.logPath})`);
  }

  /** Pin the next block's base fee to the gas price the bundles were priced at. */
  public async setNextBlockBaseFee(): Promise<void> {
    await this.provider.send("anvil_setNextBlockBaseFeePerGas", [ANVIL_GAS_PRICE.toHexString()]);
  }

  public async stop(): Promise<void> {
    if (this.child.exitCode !== null) return;
    const exited = new Promise<boolean>((resolve) => this.child.once("exit", () => resolve(true)));
    this.child.kill("SIGTERM");
    if (!(await Promise.race([exited, delay(ANVIL_STOP_TIMEOUT_MS).then(() => false)]))) this.child.kill("SIGKILL");
  }
}

/** Start a fork, run `action` against it and always stop the fork afterwards. */
export async function withAnvilFork<T>(options: AnvilForkOptions, action: (fork: AnvilFork) => Promise<T>): Promise<T> {
  const fork = await AnvilFork.start(options);
  try {
    return await action(fork);
  } finally {
    await fork.stop();
  }
}

// ─── Funding ─────────────────────────────────────────────────────────────────────

export interface FundBundleTargetsOptions {
  environment: UpgradeEnvironment;
  manifestPath: string;
  ecosystemTomlPath: string;
  deployerAddress: string;
}

export async function fundBundleTargets(
  provider: ethers.providers.JsonRpcProvider,
  options: FundBundleTargetsOptions
): Promise<void> {
  const { bridgehubAddress, zkAssetId, hasGateway } = options.environment;
  const bridgehub = new ethers.Contract(bridgehubAddress, getAbi("L1Bridgehub"), provider);
  const assetRouterAddress = ethers.utils.getAddress(await bridgehub.assetRouter());
  const assetRouter = new ethers.Contract(assetRouterAddress, getAbi("L1AssetRouter"), provider);
  const nativeTokenVaultAddress = ethers.utils.getAddress(await assetRouter.nativeTokenVault());
  const nativeTokenVault = new ethers.Contract(nativeTokenVaultAddress, getAbi("L1NativeTokenVault"), provider);
  const zkTokenAddress = ethers.utils.getAddress(await nativeTokenVault.tokenAddress(zkAssetId));

  console.log(`Asset router:      ${assetRouterAddress}`);
  console.log(`Native token vault: ${nativeTokenVaultAddress}`);
  console.log(`ZK token:           ${zkTokenAddress}`);
  await provider.send("anvil_setBalance", [nativeTokenVaultAddress, ANVIL_BALANCE.toHexString()]);

  const manifest = readJsonAs(options.manifestPath, bundleManifestSchema);
  const targets = [...new Set(manifest.bundles.map((bundle) => ethers.utils.getAddress(bundle.target).toLowerCase()))]
    .sort()
    .map((address) => ethers.utils.getAddress(address));
  console.log(`Bundle targets:\n${targets.map((target) => `  ${target}`).join("\n")}`);
  const zkToken = new ethers.Contract(
    zkTokenAddress,
    getAbi("BridgedStandardERC20"),
    provider.getSigner(nativeTokenVaultAddress)
  );
  for (const target of targets) {
    await provider.send("anvil_setBalance", [target, ANVIL_BALANCE.toHexString()]);
    console.log(
      `  bridgeMint(${target}, ${BUNDLE_TARGET_TOKEN_FUNDING.toString()})${hasGateway ? "" : " [best-effort]"}`
    );
    try {
      await (await zkToken.bridgeMint(target, BUNDLE_TARGET_TOKEN_FUNDING)).wait();
    } catch (error) {
      if (hasGateway) throw error;
    }
  }

  const { asset_tracker_proxy_addr: assetTrackerAddress } = readTomlAs(options.ecosystemTomlPath, ecosystemTomlSchema);
  if (!assetTrackerAddress) {
    console.warn(
      `  WARNING: asset_tracker_proxy_addr not found in ${options.ecosystemTomlPath} — skipping registerLegacyToken`
    );
    return;
  }
  const assetTracker = new ethers.Contract(
    ethers.utils.getAddress(assetTrackerAddress),
    getAbi("L1AssetTracker"),
    provider.getSigner(ethers.utils.getAddress(options.deployerAddress))
  );
  console.log(`  registerLegacyToken(${zkAssetId}) on ${assetTracker.address}`);
  try {
    await (await assetTracker.registerLegacyToken(zkAssetId)).wait();
  } catch {
    // The setup is intentionally idempotent: registration may already exist.
  }
}

// ─── protocol_ops ────────────────────────────────────────────────────────────────

export interface PrepareUpgradeOptions {
  environment: string;
  bridgehub: string;
  rpcUrl: string;
  deployer: string;
  outputDirectory: string;
}

export interface BroadcastUpgradeOptions {
  manifestPath: string;
  rpcUrl: string;
  outputPath: string;
  deployer?: string;
  privateKey?: string;
}

export interface VerifyUpgradeOptions {
  environment: string;
  ecosystemTomlPath: string;
  rpcUrl: string;
  gatewayRpcUrl: string;
  transactionsLogPath: string;
  zkGovernanceCommit: string;
}

export class ProtocolOps {
  public constructor(public readonly executable = locateProtocolOps()) {}

  public prepare(options: PrepareUpgradeOptions): Promise<void> {
    return runCommand(this.executable, [
      "ecosystem",
      "upgrade-prepare-all",
      "--env",
      options.environment,
      "--bridgehub",
      options.bridgehub,
      "--l1-rpc-url",
      options.rpcUrl,
      "--deployer-address",
      options.deployer,
      "--out",
      options.outputDirectory,
      `--additional-args=--memory-limit=${PROTOCOL_OPS_MEMORY_LIMIT}`,
    ]);
  }

  public broadcast(options: BroadcastUpgradeOptions): Promise<void> {
    const args = [
      "ecosystem",
      "upgrade-broadcast",
      "--manifest",
      options.manifestPath,
      "--l1-rpc-url",
      options.rpcUrl,
      "--out",
      options.outputPath,
    ];
    if (options.privateKey) {
      if (!options.deployer) throw new Error("deployer is required when broadcasting with a private key");
      args.push("--key", `${options.deployer}=${options.privateKey}`, "--skip-unkeyed");
    } else {
      args.push("--unlocked");
    }
    return runCommand(this.executable, args);
  }

  public verify(options: VerifyUpgradeOptions): Promise<void> {
    return runCommand(this.executable, [
      "ecosystem",
      "verify-upgrade",
      "--env",
      options.environment,
      "--ecosystem-toml",
      options.ecosystemTomlPath,
      "--l1-rpc-url",
      options.rpcUrl,
      "--gw-rpc-url",
      options.gatewayRpcUrl,
      "--transactions-log",
      options.transactionsLogPath,
      "--zk-governance-commit",
      options.zkGovernanceCommit,
    ]);
  }
}
