import { spawn, spawnSync } from "child_process";
import { createHash } from "crypto";
import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "@iarna/toml";
import { ethers } from "ethers";

// ─── Constants ───────────────────────────────────────────────────────────────────

export const DEPLOY_BUNDLE_SCHEMA = "zksync-ecosystem-upgrade-deploy-bundle/1";
export const V31_UPGRADE_NAME = "v0.31.0-interopB";

export const ENV_ANVIL_PORTS = {
  stage: 29_545,
  testnet: 29_547,
  mainnet: 29_549,
} as const;
export const REPLAY_PORT_OFFSET = 1;

export const ANVIL_GAS_PRICE = ethers.utils.parseUnits("1", "gwei");
export const ANVIL_BALANCE = ethers.utils.parseEther("10000");
export const BUNDLE_TARGET_TOKEN_FUNDING = ethers.utils.parseEther("1000000000000");
export const ANVIL_READY_ATTEMPTS = 30;
export const ANVIL_READY_DELAY_MS = 1_000;
export const ANVIL_STOP_TIMEOUT_MS = 5_000;
export const PROTOCOL_OPS_MEMORY_LIMIT = 536_870_912;

export const DEFAULT_GATEWAY_RPC_URL = "https://zksync-os-stage-gateway.zksync.dev";
export const DEFAULT_ZK_GOVERNANCE_COMMIT = "cc7c76d";

export const CANONICAL_DEFAULT_ACCOUNT_HASH = "0x010005f9d84c1863bf21a9393f2fd1631af92aab68f12c35dba580c8d7a06146";
export const CANONICAL_DEFAULT_ACCOUNT_EXECUTABLE_SHA256 =
  "28c736311a2f872a0b8ff289b0ae35266f1ccd402885435fd9ffd2a154a39a96";
export const CANONICAL_DEFAULT_ACCOUNT_METADATA_WORD =
  "3ad06056e66b778b11945dd3cf11269b479679b45850c25af96c8ca9f309acb0";
export const DEFAULT_ACCOUNT_METADATA_WORD_BYTES = 32;
export const ERAVM_BYTECODE_WORD_BYTES = 32;
export const ERAVM_HASH_VERSION = 1;
export const ERAVM_HASH_VERSION_OFFSET = 0;
export const ERAVM_HASH_RESERVED_OFFSET = 1;
export const ERAVM_HASH_LENGTH_OFFSET = 2;
export const MAX_ERAVM_BYTECODE_WORDS = 0xffff;

export const CREATE2_SALT_BYTES = 32;
export const FUNCTION_SELECTOR_BYTES = 4;
export const SIGINT_EXIT_CODE = 130;
export const SIGTERM_EXIT_CODE = 143;

export const SUPPORTING_BUNDLE_FILES = [
  "prepare/manifest.json",
  "ecosystem.toml",
  "extra-verification-logs.txt",
  "gw-verification-logs.txt",
] as const;

export const REQUIRED_SUPPORTING_BUNDLE_FILES = ["prepare/manifest.json", "ecosystem.toml"] as const;

// ─── Types ───────────────────────────────────────────────────────────────────────

export interface ManifestBundle {
  index: number;
  file: string;
  target: string;
  steps?: unknown[];
}

export interface BundleManifest {
  bundles: ManifestBundle[];
}

export interface SafeTransaction {
  to?: string;
  value?: string;
  data?: string;
}

export interface SafeBundle {
  transactions: SafeTransaction[];
}

export interface PackedBundle extends ManifestBundle {
  transaction_count: number;
  is_deployer_bundle: boolean | null;
  sha256: string;
}

export interface DeployBundleMetadata {
  schema: string;
  upgrade: string;
  env: string;
  protocol_version: {
    old: string[];
    new: string[];
  };
  contracts_commit: string;
  contracts_worktree_dirty: boolean;
  all_contracts_hashes_sha256: string;
  l1: {
    chain_id: number | null;
    forked_at_block: number | null;
  };
  deployer_address: string | null;
  deployer_dependent_deployments: Array<{ address: string; contract: string }>;
  zk_governance_commit: string | null;
  toolchain: {
    forge: string;
    rustc: string;
    foundry_zksync: string | null;
  };
  generated_by: { workflow_run: string; runner_os: string | null } | null;
  files: Record<string, string>;
  bundles: PackedBundle[];
}

export type TomlRecord = Record<string, unknown>;

// ─── File system + TOML ──────────────────────────────────────────────────────────

function findPackageDirectory(start: string): string {
  let current = path.resolve(start);
  let previous = "";
  while (current !== previous) {
    const packagePath = path.join(current, "package.json");
    if (fs.existsSync(packagePath) && readJson<{ name?: string }>(packagePath).name === "anvil-interop") return current;
    previous = current;
    current = path.dirname(current);
  }
  throw new Error("Cannot locate the anvil-interop package directory");
}

export const ANVIL_INTEROP_DIR = findPackageDirectory(__dirname);
export const L1_CONTRACTS_DIR = path.resolve(ANVIL_INTEROP_DIR, "../..");
export const REPO_ROOT = path.resolve(L1_CONTRACTS_DIR, "..");

export function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

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

function tomlValue(config: TomlRecord, keyPath: string): unknown {
  return keyPath.split(".").reduce<unknown>((value, key) => {
    if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
    return (value as TomlRecord)[key];
  }, config);
}

export function requireTomlString(config: TomlRecord, keyPath: string, source: string): string {
  const value = tomlValue(config, keyPath);
  if (typeof value !== "string" || value.length === 0) throw new Error(`${keyPath} not found in ${source}`);
  return value;
}

export function optionalTomlString(config: TomlRecord, keyPath: string): string | undefined {
  const value = tomlValue(config, keyPath);
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function optionalTomlInteger(config: TomlRecord, keyPath: string): number | undefined {
  const value = tomlValue(config, keyPath);
  return typeof value === "number" && Number.isSafeInteger(value) ? value : undefined;
}

export function fileSha256(filePath: string): string {
  return createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

export function requireFile(filePath: string, context = "file"): void {
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    throw new Error(`${context} not found: ${filePath}`);
  }
}

function escapesDirectory(relativePath: string): boolean {
  return relativePath === ".." || relativePath.startsWith(`..${path.sep}`) || path.isAbsolute(relativePath);
}

export function resolveContainedFile(directory: string, relativePath: string, context: string): string {
  if (!relativePath) throw new Error(`${context}: empty file path`);
  const root = fs.realpathSync(directory);
  const candidatePath = path.resolve(root, relativePath);
  const unresolvedRelative = path.relative(root, candidatePath);
  if (escapesDirectory(unresolvedRelative)) {
    throw new Error(`${context}: ${relativePath}`);
  }
  requireFile(candidatePath, context);
  const candidate = fs.realpathSync(candidatePath);
  const relative = path.relative(root, candidate);
  if (escapesDirectory(relative)) throw new Error(`${context}: ${relativePath}`);
  return candidate;
}

export function writeCombinedLog(destination: string, sources: string[]): void {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const contents = sources.filter((source) => fs.existsSync(source)).map((source) => fs.readFileSync(source));
  fs.writeFileSync(destination, Buffer.concat(contents));
}

export function parseInteger(value: string | undefined, label: string): number | undefined {
  if (value === undefined || value === "") return undefined;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${label} must be a non-negative integer`);
  return parsed;
}

// ─── Processes ───────────────────────────────────────────────────────────────────

function isExecutable(filePath: string): boolean {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function findExecutableOnPath(executable: string): string | undefined {
  return process.env.PATH?.split(path.delimiter)
    .map((directory) => path.join(directory, executable))
    .find(isExecutable);
}

export function locateProtocolOps(protocolOpsDirectory = path.join(REPO_ROOT, "protocol-ops")): string {
  const executable = [
    path.join(protocolOpsDirectory, "target/debug/protocol_ops"),
    path.join(protocolOpsDirectory, "target/release/protocol_ops"),
    path.join(protocolOpsDirectory, "protocol_ops"),
    findExecutableOnPath("protocol_ops"),
  ].find((candidate): candidate is string => candidate !== undefined && isExecutable(candidate));
  if (executable) return executable;
  throw new Error("protocol_ops binary not found — build it with 'cd protocol-ops && cargo build --release'");
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

export function commandSucceeds(command: string, args: string[], cwd?: string): boolean {
  return spawnSync(command, args, { cwd, stdio: "ignore" }).status === 0;
}

// ─── Upgrade environments ────────────────────────────────────────────────────────

export type UpgradeEnvironmentName = keyof typeof ENV_ANVIL_PORTS;

export interface UpgradeEnvironment {
  name: UpgradeEnvironmentName;
  outputDirectory: string;
  bridgehubAddress: string;
  zkAssetId: string;
  hasGateway: boolean;
}

export function parseUpgradeEnvironment(environment: string): UpgradeEnvironmentName {
  if (!Object.prototype.hasOwnProperty.call(ENV_ANVIL_PORTS, environment)) {
    throw new Error(
      `Unknown env '${environment}' (expected: ${Object.keys(ENV_ANVIL_PORTS).join(" | ")}). ` +
        "Add a dedicated port in upgrade-bundle/constants.ts."
    );
  }
  return environment as UpgradeEnvironmentName;
}

export function anvilPort(environment: UpgradeEnvironmentName): number {
  return ENV_ANVIL_PORTS[environment];
}

export function loadUpgradeEnvironment(name: UpgradeEnvironmentName): UpgradeEnvironment {
  const outputDirectory = path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, "output", name);
  const permanentValuesPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs/permanent-values", `${name}.toml`);
  const inputPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, `${name}.toml`);
  requireFile(permanentValuesPath, `config for env '${name}'`);
  requireFile(inputPath, `config for env '${name}'`);

  const permanentValues = readToml(permanentValuesPath);
  const input = readToml(inputPath);
  const bridgehubAddress = ethers.utils.getAddress(
    requireTomlString(input, "contracts.bridgehub_proxy_address", inputPath)
  );
  const zkAssetId = requireTomlString(permanentValues, "zk_token_asset_id", permanentValuesPath);
  if (!ethers.utils.isHexString(zkAssetId, 32)) {
    throw new Error(`zk_token_asset_id in ${permanentValuesPath} must be 32 bytes`);
  }

  return {
    name,
    outputDirectory,
    bridgehubAddress,
    zkAssetId,
    hasGateway: permanentValues.new_gateway !== undefined,
  };
}
