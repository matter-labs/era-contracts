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
  SIGINT_EXIT_CODE,
  SIGTERM_EXIT_CODE,
  bundleManifestSchema,
  ecosystemTomlSchema,
  locateProtocolOps,
  readJsonAs,
  readTomlAs,
  runCommand,
} from "./common";

// ─── Anvil fork ──────────────────────────────────────────────────────────────────

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function isReady(provider: ethers.providers.JsonRpcProvider): Promise<boolean> {
  try {
    await provider.send("eth_chainId", []);
    return true;
  } catch {
    return false;
  }
}

async function stopProcess(child: ChildProcess): Promise<void> {
  if (!child.pid || child.exitCode !== null) return;
  const exitPromise = new Promise<boolean>((resolve) => child.once("exit", () => resolve(true)));
  child.kill("SIGTERM");
  const exited = await Promise.race([exitPromise, delay(ANVIL_STOP_TIMEOUT_MS).then(() => false)]);
  if (!exited && child.exitCode === null) child.kill("SIGKILL");
}

export interface AnvilForkOptions {
  port: number;
  forkUrl: string;
  forkBlock?: number;
  logPath: string;
}

export class AnvilFork {
  public readonly rpcUrl: string;
  public readonly provider: ethers.providers.JsonRpcProvider;
  private child?: ChildProcess;
  private disposed = false;

  private constructor(rpcUrl: string, child?: ChildProcess) {
    this.rpcUrl = rpcUrl;
    this.provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    this.child = child;
  }

  public static async connectOrStart(options: AnvilForkOptions): Promise<AnvilFork> {
    const rpcUrl = `http://localhost:${options.port}`;
    const existing = new ethers.providers.JsonRpcProvider(rpcUrl);
    if (await isReady(existing)) {
      console.log(`=== Step 0: reusing anvil on ${rpcUrl} ===`);
      return new AnvilFork(rpcUrl);
    }

    console.log(`=== Step 0: anvil fork on port ${options.port} ===`);
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
    if (options.forkBlock !== undefined) {
      console.log(`    pinning fork to block ${options.forkBlock}`);
      args.push("--fork-block-number", String(options.forkBlock));
    }

    fs.mkdirSync(path.dirname(options.logPath), { recursive: true });
    const log = fs.openSync(options.logPath, "w");
    const child = spawn("anvil", args, { stdio: ["ignore", log, log] });
    fs.closeSync(log);
    await new Promise<void>((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", reject);
    });

    const fork = new AnvilFork(rpcUrl, child);
    for (let attempt = 0; attempt < ANVIL_READY_ATTEMPTS; attempt += 1) {
      if (await isReady(fork.provider)) return fork;
      if (child.exitCode !== null) {
        throw new Error(`anvil exited with code ${child.exitCode} before becoming ready (see ${options.logPath})`);
      }
      await delay(ANVIL_READY_DELAY_MS);
    }
    await fork.dispose(false);
    throw new Error(`anvil failed to start (see ${options.logPath})`);
  }

  public async run<T>(keepAlive: boolean, action: (fork: AnvilFork) => Promise<T>): Promise<T> {
    const exitAfterCleanup = (exitCode: number): void => {
      void this.dispose(keepAlive).finally(() => process.exit(exitCode));
    };
    const interruptHandler = (): void => exitAfterCleanup(SIGINT_EXIT_CODE);
    const terminateHandler = (): void => exitAfterCleanup(SIGTERM_EXIT_CODE);
    process.once("SIGINT", interruptHandler);
    process.once("SIGTERM", terminateHandler);
    try {
      return await action(this);
    } finally {
      process.removeListener("SIGINT", interruptHandler);
      process.removeListener("SIGTERM", terminateHandler);
      await this.dispose(keepAlive);
    }
  }

  public async setNextBlockBaseFee(): Promise<void> {
    await this.provider.send("anvil_setNextBlockBaseFeePerGas", [ANVIL_GAS_PRICE.toHexString()]);
  }

  private async dispose(keepAlive: boolean): Promise<void> {
    if (this.disposed || !this.child) return;
    this.disposed = true;
    const child = this.child;
    this.child = undefined;
    if (keepAlive) {
      console.log(`Leaving anvil (pid ${child.pid}) running on ${this.rpcUrl} (KEEP_ANVIL=1)`);
      child.unref();
      return;
    }
    console.log(`Stopping anvil (pid ${child.pid})...`);
    await stopProcess(child);
  }
}

// ─── Funding ─────────────────────────────────────────────────────────────────────

export interface FundBundleTargetsOptions {
  bridgehubAddress: string;
  zkAssetId: string;
  hasGateway: boolean;
  manifestPath: string;
  ecosystemTomlPath: string;
  deployerAddress: string;
}

export async function fundBundleTargets(
  provider: ethers.providers.JsonRpcProvider,
  options: FundBundleTargetsOptions
): Promise<void> {
  const bridgehub = new ethers.Contract(options.bridgehubAddress, getAbi("L1Bridgehub"), provider);
  const assetRouterAddress = ethers.utils.getAddress(await bridgehub.assetRouter());
  const assetRouter = new ethers.Contract(assetRouterAddress, getAbi("L1AssetRouter"), provider);
  const nativeTokenVaultAddress = ethers.utils.getAddress(await assetRouter.nativeTokenVault());
  const nativeTokenVault = new ethers.Contract(nativeTokenVaultAddress, getAbi("L1NativeTokenVault"), provider);
  const zkTokenAddress = ethers.utils.getAddress(await nativeTokenVault.tokenAddress(options.zkAssetId));

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
      `  bridgeMint(${target}, ${BUNDLE_TARGET_TOKEN_FUNDING.toString()})${options.hasGateway ? "" : " [best-effort]"}`
    );
    try {
      await (await zkToken.bridgeMint(target, BUNDLE_TARGET_TOKEN_FUNDING)).wait();
    } catch (error) {
      if (options.hasGateway) throw error;
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
  console.log(`  registerLegacyToken(${options.zkAssetId}) on ${assetTracker.address}`);
  try {
    await (await assetTracker.registerLegacyToken(options.zkAssetId)).wait();
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
