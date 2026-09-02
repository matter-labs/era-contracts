import { spawn, spawnSync } from "child_process";
import type { ChildProcess } from "child_process";
import { createHash } from "crypto";
import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "toml";
import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import {
  ANVIL_BALANCE_HEX,
  ANVIL_GAS_PRICE_WEI,
  ANVIL_READY_ATTEMPTS,
  ANVIL_READY_DELAY_MS,
  ANVIL_STOP_TIMEOUT_MS,
  BUNDLE_TARGET_TOKEN_FUNDING_WEI,
  DEPLOY_BUNDLE_SCHEMA,
  ENV_ANVIL_PORTS,
  REQUIRED_SUPPORTING_BUNDLE_FILES,
} from "./constants";
import type { BundleManifest, DeployBundleMetadata, SafeBundle, TomlRecord } from "./types";

function findPackageDirectory(start: string): string {
  let current = path.resolve(start);
  let previous = "";
  while (current !== previous) {
    const packagePath = path.join(current, "package.json");
    if (fs.existsSync(packagePath)) {
      const packageJson = readJson<{ name?: string }>(packagePath);
      if (packageJson.name === "anvil-interop") return current;
    }
    previous = current;
    current = path.dirname(current);
  }
  throw new Error("Cannot locate the anvil-interop package directory");
}

export const ANVIL_INTEROP_DIR = findPackageDirectory(__dirname);
export const L1_CONTRACTS_DIR = path.resolve(ANVIL_INTEROP_DIR, "../..");
export const REPO_ROOT = path.resolve(L1_CONTRACTS_DIR, "..");

export function readJson<T>(filePath: string): T {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
  } catch (error) {
    throw new Error(`Cannot read JSON ${filePath}: ${formatError(error)}`);
  }
}

export function readToml(filePath: string): TomlRecord {
  try {
    return parseToml(fs.readFileSync(filePath, "utf8")) as TomlRecord;
  } catch (error) {
    throw new Error(`Cannot read TOML ${filePath}: ${formatError(error)}`);
  }
}

export function requireTomlString(config: TomlRecord, key: string, source: string): string {
  const value = config[key];
  if (typeof value !== "string" || value.length === 0) throw new Error(`${key} not found in ${source}`);
  return value;
}

export function optionalTomlString(config: TomlRecord, key: string): string | undefined {
  const value = config[key];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function optionalTomlInteger(config: TomlRecord, key: string): number | undefined {
  const value = config[key];
  return typeof value === "number" && Number.isSafeInteger(value) ? value : undefined;
}

export function fileSha256(filePath: string): string {
  return createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

export function envFlag(name: string): boolean {
  return process.env[name] === "1";
}

export function requireFile(filePath: string, context = "file"): void {
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    throw new Error(`${context} not found: ${filePath}`);
  }
}

export function envAnvilPort(environment: string): number {
  const port = ENV_ANVIL_PORTS[environment];
  if (port === undefined) {
    throw new Error(
      `Unknown env '${environment}' (expected: ${Object.keys(ENV_ANVIL_PORTS).join(" | ")}). ` +
        "Add a dedicated port in upgrade-bundle/constants.ts."
    );
  }
  return port;
}

export function locateProtocolOps(protocolOpsDirectory = path.join(REPO_ROOT, "protocol-ops")): string {
  const candidates = [
    path.join(protocolOpsDirectory, "target/debug/protocol_ops"),
    path.join(protocolOpsDirectory, "target/release/protocol_ops"),
    path.join(protocolOpsDirectory, "protocol_ops"),
  ];
  for (const candidate of candidates) {
    if (isExecutable(candidate)) return candidate;
  }
  const fromPath = spawnSync("sh", ["-c", "command -v protocol_ops"], { encoding: "utf8" });
  if (fromPath.status === 0 && fromPath.stdout.trim()) return fromPath.stdout.trim();
  throw new Error("protocol_ops binary not found — build it with 'cd protocol-ops && cargo build --release'");
}

function isExecutable(filePath: string): boolean {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export async function runCommand(
  command: string,
  args: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv; quiet?: boolean } = {}
): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env ?? process.env,
      stdio: options.quiet ? "ignore" : "inherit",
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with ${signal ? `signal ${signal}` : `code ${String(code)}`}`));
    });
  });
}

export function captureCommand(command: string, args: string[], cwd?: string, fallback?: string): string {
  const result = spawnSync(command, args, { cwd, encoding: "utf8" });
  if (result.status === 0) return result.stdout.trim();
  if (fallback !== undefined) return fallback;
  throw new Error(`${command} failed: ${(result.stderr || result.stdout).trim()}`);
}

export function isRpcReady(rpcUrl: string): Promise<boolean> {
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  return provider
    .send("eth_chainId", [])
    .then(() => true)
    .catch(() => false);
}

export async function startAnvilFork(params: {
  port: number;
  forkUrl: string;
  forkBlock?: number;
  logPath: string;
}): Promise<ChildProcess> {
  const args = [
    "--port",
    String(params.port),
    "--auto-impersonate",
    "--disable-block-gas-limit",
    "--gas-price",
    String(ANVIL_GAS_PRICE_WEI),
    "--fork-url",
    params.forkUrl,
  ];
  if (params.forkBlock !== undefined) {
    console.log(`    pinning fork to block ${params.forkBlock}`);
    args.push("--fork-block-number", String(params.forkBlock));
  }
  fs.mkdirSync(path.dirname(params.logPath), { recursive: true });
  const logFd = fs.openSync(params.logPath, "w");
  const child = spawn("anvil", args, { stdio: ["ignore", logFd, logFd] });
  fs.closeSync(logFd);
  await new Promise<void>((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });

  const rpcUrl = `http://localhost:${params.port}`;
  for (let attempt = 0; attempt < ANVIL_READY_ATTEMPTS; attempt += 1) {
    if (await isRpcReady(rpcUrl)) return child;
    if (child.exitCode !== null) {
      throw new Error(`anvil exited with code ${child.exitCode} before becoming ready (see ${params.logPath})`);
    }
    await delay(ANVIL_READY_DELAY_MS);
  }
  await stopAnvil(child);
  throw new Error(`anvil failed to start (see ${params.logPath})`);
}

export async function stopAnvil(child: ChildProcess | undefined): Promise<void> {
  if (!child?.pid || child.exitCode !== null) return;
  const exitPromise = new Promise<boolean>((resolve) => child.once("exit", () => resolve(true)));
  child.kill("SIGTERM");
  const exited = await Promise.race([exitPromise, delay(ANVIL_STOP_TIMEOUT_MS).then(() => false)]);
  if (!exited && child.exitCode === null) child.kill("SIGKILL");
}

export async function fundBundleTargets(params: {
  rpcUrl: string;
  bridgehub: string;
  zkAssetId: string;
  hasGateway: boolean;
  manifestPath: string;
  ecosystemTomlPath: string;
  deployer: string;
}): Promise<void> {
  const provider = new ethers.providers.JsonRpcProvider(params.rpcUrl);
  const bridgehub = new ethers.Contract(params.bridgehub, getAbi("L1Bridgehub"), provider);
  const assetRouterAddress: string = await bridgehub.assetRouter();
  const assetRouter = new ethers.Contract(assetRouterAddress, getAbi("L1AssetRouter"), provider);
  const ntvAddress: string = await assetRouter.nativeTokenVault();
  const ntv = new ethers.Contract(ntvAddress, getAbi("L1NativeTokenVault"), provider);
  const zkTokenAddress: string = await ntv.tokenAddress(params.zkAssetId);

  console.log(`AR=${assetRouterAddress}`);
  console.log(`NTV=${ntvAddress}`);
  console.log(`ZK_TOKEN=${zkTokenAddress}`);
  await provider.send("anvil_setBalance", [ntvAddress, ANVIL_BALANCE_HEX]);

  const manifest = readJson<BundleManifest>(params.manifestPath);
  const targets = [...new Set(manifest.bundles.map((bundle) => bundle.target))].sort();
  console.log(`Bundle targets:\n${targets.map((target) => `  ${target}`).join("\n")}`);
  const zkToken = new ethers.Contract(zkTokenAddress, getAbi("BridgedStandardERC20"), provider.getSigner(ntvAddress));
  for (const target of targets) {
    await provider.send("anvil_setBalance", [target, ANVIL_BALANCE_HEX]);
    console.log(
      `  bridgeMint(${target}, ${BUNDLE_TARGET_TOKEN_FUNDING_WEI})${params.hasGateway ? "" : " [best-effort]"}`
    );
    try {
      const transaction = await zkToken.bridgeMint(target, BUNDLE_TARGET_TOKEN_FUNDING_WEI);
      await transaction.wait();
    } catch (error) {
      if (params.hasGateway) throw error;
    }
  }

  const ecosystem = readToml(params.ecosystemTomlPath);
  const assetTracker = optionalTomlString(ecosystem, "asset_tracker_proxy_addr");
  if (!assetTracker) {
    console.warn(
      `  WARNING: asset_tracker_proxy_addr not found in ${params.ecosystemTomlPath} — skipping registerLegacyToken`
    );
    return;
  }
  console.log(`  registerLegacyToken(${params.zkAssetId}) on ${assetTracker}`);
  const tracker = new ethers.Contract(assetTracker, getAbi("L1AssetTracker"), provider.getSigner(params.deployer));
  try {
    const transaction = await tracker.registerLegacyToken(params.zkAssetId);
    await transaction.wait();
  } catch {
    // The setup is intentionally idempotent: registration may already exist.
  }
}

export function envHasGateway(permanentValues: TomlRecord): boolean {
  return permanentValues.new_gateway !== undefined;
}

export function writeCombinedLog(destination: string, sources: string[]): void {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const contents = sources.filter((source) => fs.existsSync(source)).map((source) => fs.readFileSync(source));
  fs.writeFileSync(destination, Buffer.concat(contents));
}

export function verifyBundleIntegrity(bundleDirectory: string): DeployBundleMetadata {
  const bundle = fs.realpathSync(bundleDirectory);
  const checkedPath = (relativePath: string): string => {
    if (!relativePath) throw new Error("deploy bundle integrity check failed: metadata contains an empty file path");
    const candidate = fs.realpathSync(path.join(bundle, relativePath));
    const relative = path.relative(bundle, candidate);
    if (relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error(`deploy bundle integrity check failed: file escapes bundle directory: ${relativePath}`);
    }
    if (!fs.statSync(candidate).isFile()) {
      throw new Error(`deploy bundle integrity check failed: missing file: ${relativePath}`);
    }
    return candidate;
  };
  const verifyDigest = (relativePath: string, expected: unknown): void => {
    if (typeof expected !== "string" || !/^[0-9a-f]{64}$/.test(expected)) {
      throw new Error(`deploy bundle integrity check failed: invalid SHA-256 for ${relativePath}`);
    }
    const actual = fileSha256(checkedPath(relativePath));
    if (actual !== expected) {
      throw new Error(
        `deploy bundle integrity check failed: SHA-256 mismatch for ${relativePath}: expected ${expected}, got ${actual}`
      );
    }
  };

  const metadata = readJson<DeployBundleMetadata>(checkedPath("bundle-metadata.json"));
  const manifest = readJson<BundleManifest>(checkedPath("prepare/manifest.json"));
  if (metadata.schema !== DEPLOY_BUNDLE_SCHEMA) {
    throw new Error(`deploy bundle integrity check failed: unsupported schema: ${String(metadata.schema)}`);
  }
  if (!Array.isArray(metadata.bundles) || metadata.bundles.length === 0) {
    throw new Error("deploy bundle integrity check failed: metadata.bundles is empty or not an array");
  }
  if (!Array.isArray(manifest.bundles) || manifest.bundles.length === 0) {
    throw new Error("deploy bundle integrity check failed: manifest.bundles is empty or not an array");
  }
  const identity = (entry: { index: number; file: string; target: string }): string => {
    if (!Number.isInteger(entry.index) || typeof entry.file !== "string" || typeof entry.target !== "string") {
      throw new Error("deploy bundle integrity check failed: invalid bundle identity");
    }
    return `${entry.index}\0${entry.file}\0${entry.target.toLowerCase()}`;
  };
  const metadataIdentities = metadata.bundles.map(identity);
  const manifestIdentities = manifest.bundles.map(identity);
  if (new Set(metadataIdentities).size !== metadataIdentities.length) {
    throw new Error("deploy bundle integrity check failed: metadata contains duplicate bundle identities");
  }
  if (metadataIdentities.sort().join("\n") !== manifestIdentities.sort().join("\n")) {
    throw new Error("deploy bundle integrity check failed: metadata bundle list does not match prepare/manifest.json");
  }
  for (const entry of metadata.bundles) {
    const relativePath = path.join("prepare", entry.file);
    verifyDigest(relativePath, entry.sha256);
    const safe = readJson<SafeBundle>(checkedPath(relativePath));
    if (!Array.isArray(safe.transactions)) {
      throw new Error(`deploy bundle integrity check failed: ${relativePath} has no transactions array`);
    }
    if (safe.transactions.length !== entry.transaction_count) {
      throw new Error(`deploy bundle integrity check failed: transaction count mismatch for ${relativePath}`);
    }
  }
  if (!metadata.files || typeof metadata.files !== "object") {
    throw new Error("deploy bundle integrity check failed: metadata.files is empty or not an object");
  }
  for (const required of REQUIRED_SUPPORTING_BUNDLE_FILES) {
    if (!(required in metadata.files)) {
      throw new Error(`deploy bundle integrity check failed: metadata.files does not include ${required}`);
    }
  }
  for (const [relativePath, digest] of Object.entries(metadata.files)) verifyDigest(relativePath, digest);
  console.log(
    `Deploy bundle integrity: OK (${metadata.bundles.length} bundle(s), ${Object.keys(metadata.files).length} supporting file(s))`
  );
  return metadata;
}

export function parseInteger(value: string | undefined, label: string): number | undefined {
  if (value === undefined || value === "") return undefined;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${label} must be a non-negative integer`);
  return parsed;
}

export function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function runCli(main: () => Promise<void> | void): void {
  Promise.resolve()
    .then(main)
    .catch((error) => {
      console.error(formatError(error));
      process.exitCode = 1;
    });
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
