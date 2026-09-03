import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import type { z } from "zod";
import {
  CREATE2_SALT_BYTES,
  DEPLOY_BUNDLE_SCHEMA,
  FUNCTION_SELECTOR_BYTES,
  L1_CONTRACTS_DIR,
  REPO_ROOT,
  REQUIRED_SUPPORTING_BUNDLE_FILES,
  SUPPORTING_BUNDLE_FILES,
  V31_UPGRADE_NAME,
  bundleManifestSchema,
  captureCommand,
  commandSucceeds,
  deployBundleMetadataSchema,
  fileSha256,
  formatError,
  parseUpgradeEnvironment,
  permanentValuesSchema,
  readJsonAs,
  readToml,
  readTomlAs,
  requireFile,
  resolveContainedFile,
  safeBundleSchema,
} from "./common";
import type { DeployBundleMetadata, ManifestBundle, PackedBundle, SafeTransaction, TomlRecord } from "./common";

// ─── Integrity ───────────────────────────────────────────────────────────────────

const INTEGRITY_ERROR = "deploy bundle integrity check failed";

export class BundleIntegrityError extends Error {
  public constructor(message: string) {
    super(`${INTEGRITY_ERROR}: ${message}`);
    this.name = "BundleIntegrityError";
  }
}

/** A bundle's identity as the manifest states it: position, file and signer. */
function bundleKey(bundle: ManifestBundle): string {
  return `${bundle.index}:${bundle.file}:${ethers.utils.getAddress(bundle.target)}`;
}

function indexBundles<Bundle extends ManifestBundle>(bundles: Bundle[], source: string): Map<string, Bundle> {
  const byKey = new Map<string, Bundle>();
  for (const bundle of bundles) {
    const key = bundleKey(bundle);
    if (byKey.has(key)) throw new BundleIntegrityError(`${source} lists bundle ${bundle.file} twice`);
    byKey.set(key, bundle);
  }
  return byKey;
}

export function verifyBundleIntegrity(bundleDirectory: string): DeployBundleMetadata {
  const containedFile = (relativePath: string): string =>
    resolveContainedFile(bundleDirectory, relativePath, `${INTEGRITY_ERROR}: file escapes bundle directory`);
  const readBundleFile = <Schema extends z.ZodTypeAny>(relativePath: string, schema: Schema): z.output<Schema> => {
    const filePath = containedFile(relativePath);
    try {
      return readJsonAs(filePath, schema);
    } catch (error) {
      throw new BundleIntegrityError(formatError(error));
    }
  };
  const verifyDigest = (relativePath: string, expected: string): void => {
    const actual = fileSha256(containedFile(relativePath));
    if (actual !== expected) {
      throw new BundleIntegrityError(`SHA-256 mismatch for ${relativePath}: expected ${expected}, got ${actual}`);
    }
  };

  const metadata = readBundleFile("bundle-metadata.json", deployBundleMetadataSchema);
  const manifest = readBundleFile("prepare/manifest.json", bundleManifestSchema);

  const packed = indexBundles(metadata.bundles, "bundle-metadata.json");
  const listed = indexBundles(manifest.bundles, "prepare/manifest.json");
  if (packed.size !== listed.size || ![...listed.keys()].every((key) => packed.has(key))) {
    throw new BundleIntegrityError("metadata bundle list does not match prepare/manifest.json");
  }

  for (const bundle of metadata.bundles) {
    const relativePath = path.join("prepare", bundle.file);
    verifyDigest(relativePath, bundle.sha256);
    const safe = readBundleFile(relativePath, safeBundleSchema);
    if (safe.transactions.length !== bundle.transaction_count) {
      throw new BundleIntegrityError(`transaction count mismatch for ${relativePath}`);
    }
  }

  for (const required of REQUIRED_SUPPORTING_BUNDLE_FILES) {
    if (!(required in metadata.files)) throw new BundleIntegrityError(`metadata.files does not include ${required}`);
  }
  for (const [relativePath, digest] of Object.entries(metadata.files)) verifyDigest(relativePath, digest);

  console.log(
    `Deploy bundle integrity: OK (${metadata.bundles.length} bundle(s), ${Object.keys(metadata.files).length} supporting file(s))`
  );
  return metadata;
}

// ─── Packing ─────────────────────────────────────────────────────────────────────

export interface BundleProvenance {
  deployerAddress?: string;
  forkedAtBlock?: number;
  zkGovernanceCommit?: string;
  foundryZksyncVersion?: string;
  github?: {
    runId: string;
    serverUrl: string;
    repository: string;
    runnerOs?: string;
  };
}

export interface PackDeployBundleOptions {
  outputDirectory?: string;
  bundleDirectory?: string;
  permanentValuesPath?: string;
  repositoryRoot?: string;
  provenance?: BundleProvenance;
}

export function bundleProvenanceFromEnvironment(overrides: BundleProvenance = {}): BundleProvenance {
  const runId = process.env.GITHUB_RUN_ID;
  const serverUrl = process.env.GITHUB_SERVER_URL;
  const repository = process.env.GITHUB_REPOSITORY;
  return {
    deployerAddress: process.env.DEPLOYER_ADDR,
    zkGovernanceCommit: process.env.ZK_GOVERNANCE_COMMIT,
    foundryZksyncVersion: process.env.ZKSYNC_FOUNDRY_VERSION,
    github:
      runId && serverUrl && repository ? { runId, serverUrl, repository, runnerOs: process.env.RUNNER_OS } : undefined,
    ...overrides,
  };
}

function protocolVersions(config: TomlRecord, key: string): string[] {
  const values = new Set<bigint>();
  const visit = (value: unknown): void => {
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (typeof value !== "object" || value === null || value instanceof Date) return;
    for (const [entryKey, entryValue] of Object.entries(value)) {
      if (entryKey === key) {
        if (typeof entryValue !== "number" || !Number.isSafeInteger(entryValue) || entryValue < 0) {
          throw new Error(`${key} must be a non-negative safe integer`);
        }
        values.add(BigInt(entryValue));
      }
      visit(entryValue);
    }
  };
  visit(config);
  return [...values]
    .sort((left, right) => (left < right ? -1 : left > right ? 1 : 0))
    .map((value) => `0x${value.toString(16)}`);
}

function checkedGeneratedFile(directory: string, relativePath: string): string {
  return resolveContainedFile(directory, relativePath, "generated bundle file escapes prepare directory");
}

function describeTransaction(
  transaction: SafeTransaction,
  create2Factory?: string
): {
  kind: string;
  tag: string;
  dataBytes: number;
} {
  const target = ethers.utils.getAddress(transaction.to);
  const isCreate2 = create2Factory !== undefined && target === create2Factory;
  const dataBytes = ethers.utils.hexDataLength(transaction.data);
  if (isCreate2 && dataBytes < CREATE2_SALT_BYTES) {
    throw new Error(`CREATE2 transaction to ${target} has no ${CREATE2_SALT_BYTES}-byte salt`);
  }
  return {
    kind: isCreate2 ? "CREATE2 deploy" : "call",
    tag: isCreate2
      ? ethers.utils.hexDataSlice(transaction.data, 0, CREATE2_SALT_BYTES)
      : ethers.utils.hexDataSlice(transaction.data, 0, Math.min(FUNCTION_SELECTOR_BYTES, dataBytes)),
    dataBytes,
  };
}

function createReadme(
  metadata: DeployBundleMetadata,
  callsMarkdown: string[],
  deployerDependent: Array<{ address: string; contract: string }>
): string {
  const deployerFiles = metadata.bundles.filter((bundle) => bundle.is_deployer_bundle).map((bundle) => bundle.file);
  const otherBundles = metadata.bundles.filter((bundle) => !bundle.is_deployer_bundle);
  const oldVersions = metadata.protocol_version.old.join(", ") || "?";
  const newVersions = metadata.protocol_version.new.join(", ") || "?";
  const deployerList = deployerFiles.map((file) => `  - \`${file}\``).join("\n") || "  (none)";
  const otherList =
    otherBundles.map((bundle) => `  - \`${bundle.file}\` (target \`${bundle.target}\`)`).join("\n") || "  (none)";
  const dependentList =
    deployerDependent.map((deployment) => `  - \`${deployment.address}\`  ${deployment.contract}`).join("\n") ||
    "  (none in this bundle)";

  return `# v31 deploy bundle — \`${metadata.env}\`

Generated from era-contracts \`${metadata.contracts_commit}\`
(\`AllContractsHashes.json\` sha256 \`${metadata.all_contracts_hashes_sha256.slice(0, 16)}…\`),
forked at L1 block \`${metadata.l1.forked_at_block}\` on chain \`${metadata.l1.chain_id}\`.
Protocol version ${oldVersions} → ${newVersions}.

\`prepare/*.safe.json\` hold the transactions to send, \`to\`/\`value\`/\`data\` as-is —
the CREATE2 init code inside them IS the bytecode that was compiled for this
bundle. Broadcasting them deploys exactly that bytecode to exactly the addresses
\`ecosystem.toml\` names. Do NOT regenerate to "refresh" the bundle: a different
build environment yields different metadata, hence different addresses.

| File | What |
|---|---|
| \`prepare/manifest.json\` | bundle list, in execution order, with each bundle's signer (\`target\`) |
| \`prepare/*.safe.json\` | the calls themselves (Safe Transaction Builder shape) |
| \`ecosystem.toml\` | resulting addresses + governance stage 0/1/2 calldata |
| \`bundle-metadata.json\` | provenance + SHA-256 for every executable/supporting file |
| \`extra-verification-logs.txt\` | \`forge verify-contract\` commands (constructor args included) |

## Who signs what

Deployer (\`${metadata.deployer_address}\`) — broadcast these:
${deployerList}

Governance / other signers — NOT for the deployer; they are the ceremony bundles
executed by their own multisig:
${otherList}

## Deploy for real

**The broadcasting EOA must be \`${metadata.deployer_address}\`.** The deployer is not a
free parameter: it is baked into the init code of ${deployerDependent.length} deployment(s),
so a different signer puts them at different CREATE2 addresses while
\`ecosystem.toml\` and the governance calldata still name these ones —
${dependentList}

\`\`\`bash
git checkout ${metadata.contracts_commit}        # bytecode identity: must match
cd protocol-ops && cargo build --release && cd ..
yarn --cwd l1-contracts/test/anvil-interop install --frozen-lockfile

yarn --cwd l1-contracts/test/anvil-interop bundle replay \\
  --bundle <this-dir> --rpc <l1-rpc> --key "$DEPLOYER_KEY"
\`\`\`

The command verifies every bundle digest and the checkout's bytecode identity,
then passes \`--skip-unkeyed\` so only the deployer bundles are sent (the governance
bundles remain for their ceremony). It appends every mined hash to
\`replay/transactions.txt\` for PUVT. The broadcast is idempotent: CREATE2 deploys
already on-chain are skipped, so a re-run after a partial deploy resumes.

## Rehearse + verify (PUVT) locally, no compiler needed

\`\`\`bash
yarn --cwd l1-contracts/test/anvil-interop bundle replay \\
  --bundle <this-dir> --fork-url <l1-rpc>
\`\`\`

That forks L1 at block \`${metadata.l1.forked_at_block}\`, funds the bundle
signers, replays every bundle under impersonation, and runs
\`ecosystem verify-upgrade\` against the result. Pass \`--rpc <url>\` instead of
\`--fork-url\` to verify an already-deployed chain.

## The calls, in execution order

Bundles are sent in \`index\` order and each bundle's transactions in listed order.
\`data\` is authoritative in the JSON; the sizes below are just for orientation.
${callsMarkdown.join("\n")}
`;
}

export function packDeployBundle(environment: string, options: PackDeployBundleOptions = {}): string {
  const environmentName = parseUpgradeEnvironment(environment);
  const outputDirectory =
    options.outputDirectory ?? path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, "output", environmentName);
  const bundleDirectory = path.resolve(
    options.bundleDirectory ?? process.env.BUNDLE_DIR ?? path.join(outputDirectory, "deploy-bundle")
  );
  const permanentValuesPath =
    options.permanentValuesPath ??
    path.join(L1_CONTRACTS_DIR, "upgrade-envs/permanent-values", `${environmentName}.toml`);
  const repositoryRoot = options.repositoryRoot ?? REPO_ROOT;
  const sourcePrepareDirectory = path.join(outputDirectory, "prepare");
  const sourceManifestPath = path.join(sourcePrepareDirectory, "manifest.json");
  requireFile(path.join(outputDirectory, "ecosystem.toml"), "generation output");
  requireFile(sourceManifestPath, "generation output");
  requireFile(permanentValuesPath, "environment config");

  const sourceManifest = readJsonAs(sourceManifestPath, bundleManifestSchema);

  fs.rmSync(bundleDirectory, { recursive: true, force: true });
  fs.mkdirSync(path.join(bundleDirectory, "prepare"), { recursive: true });
  fs.copyFileSync(path.join(outputDirectory, "ecosystem.toml"), path.join(bundleDirectory, "ecosystem.toml"));
  fs.copyFileSync(sourceManifestPath, path.join(bundleDirectory, "prepare/manifest.json"));
  for (const bundle of sourceManifest.bundles) {
    const source = checkedGeneratedFile(sourcePrepareDirectory, bundle.file);
    fs.copyFileSync(source, path.join(bundleDirectory, "prepare", bundle.file));
  }
  for (const log of ["extra-verification-logs.txt", "gw-verification-logs.txt"]) {
    const source = path.join(outputDirectory, log);
    if (fs.existsSync(source) && fs.statSync(source).size > 0) fs.copyFileSync(source, path.join(bundleDirectory, log));
  }

  const contractsCommit = captureCommand("git", ["rev-parse", "HEAD"], repositoryRoot, "unknown");
  const worktreeIsClean = commandSucceeds(
    "git",
    ["diff", "--quiet", "HEAD", "--ignore-submodules=all"],
    repositoryRoot
  );
  const permanentValues = readTomlAs(permanentValuesPath, permanentValuesSchema);
  const provenance = options.provenance ?? {};
  const deployer = provenance.deployerAddress ? ethers.utils.getAddress(provenance.deployerAddress) : undefined;
  const configuredCreate2Factory = permanentValues.permanent_contracts?.create2_factory_addr;
  const create2Factory = configuredCreate2Factory ? ethers.utils.getAddress(configuredCreate2Factory) : undefined;
  const callsMarkdown: string[] = [];
  const bundles: PackedBundle[] = [...sourceManifest.bundles]
    .sort((left, right) => left.index - right.index)
    .map((bundle) => {
      const relativePath = path.join("prepare", bundle.file);
      const safePath = path.join(bundleDirectory, relativePath);
      const safe = readJsonAs(safePath, safeBundleSchema);
      const target = ethers.utils.getAddress(bundle.target);
      const role = deployer === target ? "DEPLOYER" : "other signer";
      callsMarkdown.push(
        `\n### Bundle ${bundle.index} — signer \`${bundle.target}\` (${role})\n\n` +
          `\`${bundle.file}\` · ${safe.transactions.length} transaction(s)\n\n` +
          "| # | to | value | kind | selector / CREATE2 salt | data bytes |\n|---|---|---|---|---|---|"
      );
      safe.transactions.forEach((transaction, index) => {
        const description = describeTransaction(transaction, create2Factory);
        callsMarkdown.push(
          `| ${index + 1} | \`${transaction.to}\` | ${transaction.value} | ${description.kind} | ` +
            `\`${description.tag}\` | ${description.dataBytes} |`
        );
      });
      return {
        ...bundle,
        target,
        steps: bundle.steps ?? [],
        transaction_count: safe.transactions.length,
        is_deployer_bundle: deployer ? target === deployer : null,
        sha256: fileSha256(safePath),
      };
    });

  const deployerDependent: Array<{ address: string; contract: string }> = [];
  const verificationLog = path.join(bundleDirectory, "extra-verification-logs.txt");
  if (deployer && fs.existsSync(verificationLog)) {
    const pattern = /forge verify-contract\s+(0x[0-9a-fA-F]{40})\s+(\S+)\s+--constructor-args\s+(0x[0-9a-fA-F]+)/g;
    const seen = new Set<string>();
    for (const match of fs.readFileSync(verificationLog, "utf8").matchAll(pattern)) {
      const address = match[1];
      const normalizedAddress = ethers.utils.getAddress(address);
      if (match[3].toLowerCase().includes(deployer.slice(2).toLowerCase()) && !seen.has(normalizedAddress)) {
        seen.add(normalizedAddress);
        deployerDependent.push({ address: normalizedAddress, contract: match[2] });
      }
    }
  }

  const supportingFiles: Record<string, string> = {};
  for (const relativePath of SUPPORTING_BUNDLE_FILES) {
    const filePath = path.join(bundleDirectory, relativePath);
    if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) supportingFiles[relativePath] = fileSha256(filePath);
  }
  const ecosystem = readToml(path.join(bundleDirectory, "ecosystem.toml"));
  const metadata: DeployBundleMetadata = {
    schema: DEPLOY_BUNDLE_SCHEMA,
    upgrade: V31_UPGRADE_NAME,
    env: environmentName,
    protocol_version: {
      old: protocolVersions(ecosystem, "old_protocol_version"),
      new: protocolVersions(ecosystem, "new_protocol_version"),
    },
    contracts_commit: contractsCommit,
    contracts_worktree_dirty: !worktreeIsClean,
    all_contracts_hashes_sha256: fileSha256(path.join(repositoryRoot, "AllContractsHashes.json")),
    l1: {
      chain_id: permanentValues.l1_chain_id ?? null,
      forked_at_block: provenance.forkedAtBlock ?? null,
    },
    deployer_address: deployer ?? null,
    deployer_dependent_deployments: deployerDependent,
    zk_governance_commit: provenance.zkGovernanceCommit ?? null,
    toolchain: {
      forge: captureCommand("forge", ["--version"], undefined, "unknown").split("\n")[0],
      rustc: captureCommand("rustc", ["--version"], undefined, "unknown"),
      foundry_zksync: provenance.foundryZksyncVersion ?? null,
    },
    generated_by: provenance.github
      ? {
          workflow_run: `${provenance.github.serverUrl}/${provenance.github.repository}/actions/runs/${provenance.github.runId}`,
          runner_os: provenance.github.runnerOs ?? null,
        }
      : null,
    files: supportingFiles,
    bundles,
  };
  fs.writeFileSync(path.join(bundleDirectory, "bundle-metadata.json"), `${JSON.stringify(metadata, null, 2)}\n`);
  fs.writeFileSync(path.join(bundleDirectory, "README.md"), createReadme(metadata, callsMarkdown, deployerDependent));

  verifyBundleIntegrity(bundleDirectory);
  console.log(`=== Deploy bundle packed: ${bundleDirectory}`);
  for (const relativePath of fs.readdirSync(bundleDirectory).sort()) console.log(`  ${relativePath}`);
  for (const relativePath of fs.readdirSync(path.join(bundleDirectory, "prepare")).sort()) {
    console.log(`  prepare/${relativePath}`);
  }
  return bundleDirectory;
}
