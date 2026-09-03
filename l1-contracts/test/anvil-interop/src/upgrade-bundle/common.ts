import { spawn, spawnSync } from "child_process";
import { createHash } from "crypto";
import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "@iarna/toml";
import { ethers } from "ethers";
import { z } from "zod";

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

export const BUNDLE_METADATA_FILE = "bundle-metadata.json";
/** Generation outputs a bundle must carry, besides the `prepare/*.safe.json` files the manifest names. */
export const REQUIRED_BUNDLE_FILES = ["prepare/manifest.json", "ecosystem.toml"] as const;
/** Etherscan verification command logs; `gw-verification-logs.txt` only exists on gateway-enabled envs. */
export const OPTIONAL_BUNDLE_FILES = ["extra-verification-logs.txt", "gw-verification-logs.txt"] as const;
/** The per-env real-network broadcast log, committed under `output/<env>/` and read by PUVT. */
export const TRANSACTIONS_LOG = "transactions.txt";

/**
 * Tracked paths whose modification changes the bytecode or calldata a generation run
 * produces. `contracts_worktree_dirty` in the bundle metadata is scoped to these, so the
 * generated files the run itself rewrites (`output/<env>/`, `zkstack-out/`) do not count.
 */
export const CONTRACT_SOURCE_PATHSPECS = [
  "*/foundry.toml",
  "AllContractsHashes.json",
  "SystemConfig.json",
  "configs/genesis",
  "da-contracts/contracts",
  "l1-contracts/contracts",
  "l1-contracts/deploy-scripts",
  "l1-contracts/upgrade-envs/permanent-values",
  "l1-contracts/upgrade-envs/v0.31.0-interopB/*.toml",
  "l2-contracts/contracts",
  "protocol-ops/src",
  "system-contracts/contracts",
] as const;

// ─── Schemas ─────────────────────────────────────────────────────────────────────

export const addressSchema = z.string().refine((value) => ethers.utils.isAddress(value), "invalid address");
export const bytes32Schema = z.string().refine((value) => ethers.utils.isHexString(value, 32), "must be 32 bytes");
export const sha256Schema = z.string().regex(/^[0-9a-f]{64}$/, "invalid SHA-256");
const bareFileNameSchema = z
  .string()
  .min(1)
  .refine((file) => path.basename(file) === file, "must be a bare file name");
const bundleRelativePathSchema = z
  .string()
  .min(1)
  .refine((file) => !path.isAbsolute(file) && !file.split("/").includes(".."), "path must stay inside the bundle");

export const packageJsonSchema = z.object({ name: z.string().optional() });

/** One entry of `prepare/manifest.json` as `upgrade-prepare-all` writes it. */
export const manifestBundleSchema = z.object({
  index: z.number().int().nonnegative(),
  file: bareFileNameSchema,
  target: addressSchema,
});
export const bundleManifestSchema = z.object({ bundles: z.array(manifestBundleSchema).min(1) });

/** `bundle-metadata.json`: provenance plus the digest of every other file in the bundle. */
export const deployBundleMetadataSchema = z.object({
  schema: z.literal(DEPLOY_BUNDLE_SCHEMA),
  upgrade: z.string(),
  env: z.string(),
  contracts_commit: z.string(),
  contracts_worktree_dirty: z.boolean(),
  all_contracts_hashes_sha256: sha256Schema,
  l1: z.object({ chain_id: z.number().int().nullable(), forked_at_block: z.number().int().nullable() }),
  deployer_address: addressSchema.nullable(),
  zk_governance_commit: z.string().nullable(),
  toolchain: z.object({ forge: z.string(), rustc: z.string(), foundry_zksync: z.string().nullable() }),
  generated_by: z.object({ workflow_run: z.string(), runner_os: z.string().nullable() }).nullable(),
  files: z.record(bundleRelativePathSchema, sha256Schema),
});

/** `permanent-values/<env>.toml`, as far as the bundle tooling reads it. */
export const permanentValuesSchema = z.object({
  l1_chain_id: z.number().int().optional(),
  zk_token_asset_id: bytes32Schema.optional(),
  new_gateway: z.unknown().optional(),
});
/** `v0.31.0-interopB/<env>.toml`, as far as the bundle tooling reads it. */
export const upgradeInputSchema = z.object({ contracts: z.object({ bridgehub_proxy_address: addressSchema }) });
/** The `ecosystem.toml` keys the fork funding reads. */
export const ecosystemTomlSchema = z.object({ asset_tracker_proxy_addr: addressSchema.optional() });

export type ManifestBundle = z.infer<typeof manifestBundleSchema>;
export type BundleManifest = z.infer<typeof bundleManifestSchema>;
export type DeployBundleMetadata = z.infer<typeof deployBundleMetadataSchema>;
export type TomlRecord = Record<string, unknown>;

// ─── File system + TOML ──────────────────────────────────────────────────────────

function findPackageDirectory(start: string): string {
  let current = path.resolve(start);
  let previous = "";
  while (current !== previous) {
    const packagePath = path.join(current, "package.json");
    if (fs.existsSync(packagePath) && readJsonAs(packagePath, packageJsonSchema).name === "anvil-interop")
      return current;
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

function formatIssues(error: z.ZodError): string {
  return error.issues.map((issue) => `${issue.path.join(".") || "<root>"}: ${issue.message}`).join("; ");
}

function parseWith<Schema extends z.ZodTypeAny>(value: unknown, schema: Schema, source: string): z.output<Schema> {
  const result = schema.safeParse(value);
  if (!result.success) throw new Error(`${source}: ${formatIssues(result.error)}`);
  return result.data;
}

/** Read a JSON file and validate it against `schema`; the result is typed by the schema. */
export function readJsonAs<Schema extends z.ZodTypeAny>(filePath: string, schema: Schema): z.output<Schema> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`Cannot read JSON ${filePath}: ${formatError(error)}`);
  }
  return parseWith(parsed, schema, filePath);
}

export function readToml(filePath: string): TomlRecord {
  try {
    return parseToml(fs.readFileSync(filePath, "utf8")) as TomlRecord;
  } catch (error) {
    throw new Error(`Cannot read TOML ${filePath}: ${formatError(error)}`);
  }
}

/** Read a TOML file and validate it against `schema`; unknown keys are dropped, not rejected. */
export function readTomlAs<Schema extends z.ZodTypeAny>(filePath: string, schema: Schema): z.output<Schema> {
  return parseWith(readToml(filePath), schema, filePath);
}

export function fileSha256(filePath: string): string {
  return createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

export function requireFile(filePath: string, context = "file"): void {
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    throw new Error(`${context} not found: ${filePath}`);
  }
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

/** Run a command with inherited stdio; rejects when it exits non-zero. */
export async function runCommand(command: string, args: string[]): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit" });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with ${signal ? `signal ${signal}` : `code ${String(code)}`}`));
    });
  });
}

/** Trimmed stdout of a command, or `undefined` when it cannot run or exits non-zero. */
export function tryCaptureCommand(command: string, args: string[], cwd?: string): string | undefined {
  const result = spawnSync(command, args, { cwd, encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : undefined;
}

export function captureCommand(command: string, args: string[], cwd: string | undefined, fallback: string): string {
  return tryCaptureCommand(command, args, cwd) ?? fallback;
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

  const permanentValues = readTomlAs(permanentValuesPath, permanentValuesSchema.required({ zk_token_asset_id: true }));
  const input = readTomlAs(inputPath, upgradeInputSchema);

  return {
    name,
    outputDirectory,
    bridgehubAddress: ethers.utils.getAddress(input.contracts.bridgehub_proxy_address),
    zkAssetId: permanentValues.zk_token_asset_id,
    hasGateway: permanentValues.new_gateway !== undefined,
  };
}
