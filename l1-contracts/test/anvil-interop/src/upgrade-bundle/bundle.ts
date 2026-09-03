import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import type { z } from "zod";
import {
  BUNDLE_METADATA_FILE,
  CONTRACT_SOURCE_PATHSPECS,
  DEPLOY_BUNDLE_SCHEMA,
  L1_CONTRACTS_DIR,
  OPTIONAL_BUNDLE_FILES,
  REPO_ROOT,
  REQUIRED_BUNDLE_FILES,
  V31_UPGRADE_NAME,
  bundleManifestSchema,
  captureCommand,
  deployBundleMetadataSchema,
  fileSha256,
  formatError,
  parseUpgradeEnvironment,
  permanentValuesSchema,
  readJsonAs,
  readTomlAs,
  requireFile,
  tryCaptureCommand,
} from "./common";
import type { DeployBundleMetadata } from "./common";

// ─── Integrity ───────────────────────────────────────────────────────────────────

export class BundleIntegrityError extends Error {
  public constructor(message: string) {
    super(`deploy bundle integrity check failed: ${message}`);
    this.name = "BundleIntegrityError";
  }
}

/**
 * Check a deploy bundle against its own metadata: every listed file must be present with
 * the recorded SHA-256, the manifest and `ecosystem.toml` must be among them, and every
 * bundle file the manifest names must be covered. The metadata is the root of trust; the
 * (digest-protected) manifest is the source of truth for what gets broadcast.
 */
export function verifyBundleIntegrity(bundleDirectory: string): DeployBundleMetadata {
  const read = <Schema extends z.ZodTypeAny>(relativePath: string, schema: Schema): z.output<Schema> => {
    try {
      return readJsonAs(path.join(bundleDirectory, relativePath), schema);
    } catch (error) {
      throw new BundleIntegrityError(formatError(error));
    }
  };

  const metadata = read(BUNDLE_METADATA_FILE, deployBundleMetadataSchema);
  for (const required of REQUIRED_BUNDLE_FILES) {
    if (!(required in metadata.files)) throw new BundleIntegrityError(`metadata.files does not include ${required}`);
  }
  for (const [relativePath, expected] of Object.entries(metadata.files)) {
    const filePath = path.join(bundleDirectory, relativePath);
    if (!fs.existsSync(filePath))
      throw new BundleIntegrityError(`${relativePath} is listed in the metadata but missing`);
    const actual = fileSha256(filePath);
    if (actual !== expected) {
      throw new BundleIntegrityError(`SHA-256 mismatch for ${relativePath}: expected ${expected}, got ${actual}`);
    }
  }
  const manifest = read("prepare/manifest.json", bundleManifestSchema);
  for (const bundle of manifest.bundles) {
    if (!(`prepare/${bundle.file}` in metadata.files)) {
      throw new BundleIntegrityError(`prepare/${bundle.file} is in the manifest but not in the metadata`);
    }
  }

  console.log(
    `Deploy bundle integrity: OK (${manifest.bundles.length} bundle(s), ${Object.keys(metadata.files).length} file(s))`
  );
  return metadata;
}

// ─── Packing ─────────────────────────────────────────────────────────────────────

/** Facts about the generation run that the bundle records but cannot derive from its files. */
export interface BundleProvenance {
  deployerAddress?: string;
  forkedAtBlock?: number;
  zkGovernanceCommit?: string;
  foundryZksyncVersion?: string;
}

export interface PackDeployBundleOptions {
  outputDirectory?: string;
  bundleDirectory?: string;
  permanentValuesPath?: string;
  repositoryRoot?: string;
  provenance?: BundleProvenance;
}

/** The GitHub Actions run that packed the bundle, or null when packed by hand. */
function githubRunProvenance(): DeployBundleMetadata["generated_by"] {
  const { GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID, RUNNER_OS } = process.env;
  if (!GITHUB_SERVER_URL || !GITHUB_REPOSITORY || !GITHUB_RUN_ID) return null;
  return {
    workflow_run: `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}`,
    runner_os: RUNNER_OS ?? null,
  };
}

/** Every regular file below `directory`, as directory-relative POSIX paths. */
function listFiles(directory: string, prefix = ""): string[] {
  return fs
    .readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) =>
      entry.isDirectory()
        ? listFiles(path.join(directory, entry.name), `${prefix}${entry.name}/`)
        : [`${prefix}${entry.name}`]
    );
}

/**
 * Copy a generation run's deployer calls, `ecosystem.toml` and verification logs into a
 * self-contained bundle directory and write `bundle-metadata.json` next to them.
 */
export function packDeployBundle(environment: string, options: PackDeployBundleOptions = {}): string {
  const environmentName = parseUpgradeEnvironment(environment);
  const outputDirectory =
    options.outputDirectory ?? path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, "output", environmentName);
  const bundleDirectory = path.resolve(options.bundleDirectory ?? path.join(outputDirectory, "deploy-bundle"));
  const permanentValuesPath =
    options.permanentValuesPath ??
    path.join(L1_CONTRACTS_DIR, "upgrade-envs/permanent-values", `${environmentName}.toml`);
  const repositoryRoot = options.repositoryRoot ?? REPO_ROOT;
  const provenance = options.provenance ?? {};

  for (const relativePath of REQUIRED_BUNDLE_FILES)
    requireFile(path.join(outputDirectory, relativePath), "generation output");
  const manifest = readJsonAs(path.join(outputDirectory, "prepare/manifest.json"), bundleManifestSchema);
  const permanentValues = readTomlAs(permanentValuesPath, permanentValuesSchema);

  fs.rmSync(bundleDirectory, { recursive: true, force: true });
  fs.mkdirSync(path.join(bundleDirectory, "prepare"), { recursive: true });
  const bundleFiles = manifest.bundles.map((bundle) => `prepare/${bundle.file}`);
  for (const relativePath of [...REQUIRED_BUNDLE_FILES, ...bundleFiles]) {
    fs.copyFileSync(path.join(outputDirectory, relativePath), path.join(bundleDirectory, relativePath));
  }
  for (const relativePath of OPTIONAL_BUNDLE_FILES) {
    const source = path.join(outputDirectory, relativePath);
    if (fs.existsSync(source) && fs.statSync(source).size > 0) {
      fs.copyFileSync(source, path.join(bundleDirectory, relativePath));
    }
  }

  // Scoped to the sources that determine the bytecode: the run itself rewrites tracked
  // generated files (output/<env>/, zkstack-out/), which must not count as a dirty tree.
  const sourceStatus = tryCaptureCommand(
    "git",
    ["status", "--porcelain", "--", ...CONTRACT_SOURCE_PATHSPECS],
    repositoryRoot
  );
  const metadata: DeployBundleMetadata = {
    schema: DEPLOY_BUNDLE_SCHEMA,
    upgrade: V31_UPGRADE_NAME,
    env: environmentName,
    contracts_commit: captureCommand("git", ["rev-parse", "HEAD"], repositoryRoot, "unknown"),
    contracts_worktree_dirty: sourceStatus === undefined || sourceStatus !== "",
    all_contracts_hashes_sha256: fileSha256(path.join(repositoryRoot, "AllContractsHashes.json")),
    l1: {
      chain_id: permanentValues.l1_chain_id ?? null,
      forked_at_block: provenance.forkedAtBlock ?? null,
    },
    deployer_address: provenance.deployerAddress ? ethers.utils.getAddress(provenance.deployerAddress) : null,
    zk_governance_commit: provenance.zkGovernanceCommit ?? null,
    toolchain: {
      forge: captureCommand("forge", ["--version"], undefined, "unknown").split("\n")[0],
      rustc: captureCommand("rustc", ["--version"], undefined, "unknown"),
      foundry_zksync: provenance.foundryZksyncVersion ?? null,
    },
    generated_by: githubRunProvenance(),
    files: Object.fromEntries(
      listFiles(bundleDirectory)
        .sort()
        .map((relativePath) => [relativePath, fileSha256(path.join(bundleDirectory, relativePath))])
    ),
  };
  fs.writeFileSync(path.join(bundleDirectory, BUNDLE_METADATA_FILE), `${JSON.stringify(metadata, null, 2)}\n`);

  verifyBundleIntegrity(bundleDirectory);
  console.log(`Deploy bundle packed: ${bundleDirectory}`);
  return bundleDirectory;
}
