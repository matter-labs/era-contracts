import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { DEPLOY_BUNDLE_SCHEMA, SUPPORTING_BUNDLE_FILES, V31_UPGRADE_NAME } from "./constants";
import {
  L1_CONTRACTS_DIR,
  REPO_ROOT,
  captureCommand,
  fileSha256,
  optionalTomlInteger,
  optionalTomlString,
  readJson,
  readToml,
  requireFile,
  verifyBundleIntegrity,
} from "./common";
import type { BundleManifest, DeployBundleMetadata, PackedBundle, SafeBundle, SafeTransaction } from "./types";

function protocolVersions(toml: string, key: string): string[] {
  const values = new Set<number>();
  const expression = new RegExp(`^${key}\\s*=\\s*(\\d+)`, "gm");
  for (const match of toml.matchAll(expression)) values.add(Number(match[1]));
  return [...values].sort((left, right) => left - right).map((value) => `0x${value.toString(16)}`);
}

function checkedGeneratedFile(directory: string, relativePath: string): string {
  const resolvedDirectory = path.resolve(directory);
  const resolvedFile = path.resolve(directory, relativePath);
  const relative = path.relative(resolvedDirectory, resolvedFile);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error(`generated bundle file escapes prepare directory: ${relativePath}`);
  }
  requireFile(resolvedFile, "generated bundle file");
  return resolvedFile;
}

function describeTransaction(
  transaction: SafeTransaction,
  create2Factory: string
): {
  kind: string;
  tag: string;
  dataBytes: number;
} {
  const data = transaction.data || "0x";
  if (!/^0x[0-9a-fA-F]*$/.test(data))
    throw new Error(`invalid transaction data for ${transaction.to ?? "unknown target"}`);
  const isCreate2 = (transaction.to ?? "").toLowerCase() === create2Factory.toLowerCase();
  return {
    kind: isCreate2 ? "CREATE2 deploy" : "call",
    tag: isCreate2 ? `0x${data.slice(2, 66)}` : data.slice(0, 10),
    dataBytes: Math.max(data.length - 2, 0) / 2,
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
yarn --cwd l1-contracts/test/anvil-interop install

yarn --cwd l1-contracts/test/anvil-interop bundle:replay -- \\
  --bundle <this-dir> --rpc <l1-rpc> --key "$DEPLOYER_KEY"
\`\`\`

The command verifies every bundle digest and the checkout's bytecode identity,
then passes \`--skip-unkeyed\` so only the deployer bundles are sent (the governance
bundles remain for their ceremony). It appends every mined hash to
\`replay/transactions.txt\` for PUVT. The broadcast is idempotent: CREATE2 deploys
already on-chain are skipped, so a re-run after a partial deploy resumes.

## Rehearse + verify (PUVT) locally, no compiler needed

\`\`\`bash
yarn --cwd l1-contracts/test/anvil-interop bundle:replay -- \\
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

export function packDeployBundle(environment: string): string {
  const outputDirectory = path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, "output", environment);
  const bundleDirectory = path.resolve(process.env.BUNDLE_DIR ?? path.join(outputDirectory, "deploy-bundle"));
  const permanentValuesPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs/permanent-values", `${environment}.toml`);
  const sourcePrepareDirectory = path.join(outputDirectory, "prepare");
  const sourceManifestPath = path.join(sourcePrepareDirectory, "manifest.json");
  requireFile(path.join(outputDirectory, "ecosystem.toml"), "generation output");
  requireFile(sourceManifestPath, "generation output");
  requireFile(permanentValuesPath, "environment config");

  const sourceManifest = readJson<BundleManifest>(sourceManifestPath);
  if (!Array.isArray(sourceManifest.bundles) || sourceManifest.bundles.length === 0) {
    throw new Error(`${sourceManifestPath} has no bundles`);
  }

  fs.rmSync(bundleDirectory, { recursive: true, force: true });
  fs.mkdirSync(path.join(bundleDirectory, "prepare"), { recursive: true });
  fs.copyFileSync(path.join(outputDirectory, "ecosystem.toml"), path.join(bundleDirectory, "ecosystem.toml"));
  fs.copyFileSync(sourceManifestPath, path.join(bundleDirectory, "prepare/manifest.json"));
  for (const bundle of sourceManifest.bundles) {
    const source = checkedGeneratedFile(sourcePrepareDirectory, bundle.file);
    fs.copyFileSync(source, path.join(bundleDirectory, "prepare", path.basename(bundle.file)));
  }
  for (const log of ["extra-verification-logs.txt", "gw-verification-logs.txt"]) {
    const source = path.join(outputDirectory, log);
    if (fs.existsSync(source) && fs.statSync(source).size > 0) fs.copyFileSync(source, path.join(bundleDirectory, log));
  }

  const contractsCommit = captureCommand("git", ["rev-parse", "HEAD"], REPO_ROOT, "unknown");
  const dirtyResult = spawnSync("git", ["diff", "--quiet", "HEAD", "--ignore-submodules=all"], { cwd: REPO_ROOT });
  const permanentValues = readToml(permanentValuesPath);
  const deployer = process.env.DEPLOYER_ADDR?.toLowerCase() ?? "";
  const create2Factory = optionalTomlString(permanentValues, "create2_factory_addr") ?? "";
  const callsMarkdown: string[] = [];
  const bundles: PackedBundle[] = [...sourceManifest.bundles]
    .sort((left, right) => left.index - right.index)
    .map((bundle) => {
      const relativePath = path.join("prepare", path.basename(bundle.file));
      const safePath = path.join(bundleDirectory, relativePath);
      const safe = readJson<SafeBundle>(safePath);
      if (!Array.isArray(safe.transactions)) throw new Error(`${safePath} has no transactions array`);
      const role = deployer && bundle.target.toLowerCase() === deployer ? "DEPLOYER" : "other signer";
      callsMarkdown.push(
        `\n### Bundle ${bundle.index} — signer \`${bundle.target}\` (${role})\n\n` +
          `\`${bundle.file}\` · ${safe.transactions.length} transaction(s)\n\n` +
          "| # | to | value | kind | selector / CREATE2 salt | data bytes |\n|---|---|---|---|---|---|"
      );
      safe.transactions.forEach((transaction, index) => {
        const description = describeTransaction(transaction, create2Factory);
        callsMarkdown.push(
          `| ${index + 1} | \`${transaction.to}\` | ${transaction.value ?? "0"} | ${description.kind} | ` +
            `\`${description.tag}\` | ${description.dataBytes} |`
        );
      });
      return {
        ...bundle,
        file: path.basename(bundle.file),
        steps: bundle.steps ?? [],
        transaction_count: safe.transactions.length,
        is_deployer_bundle: deployer ? bundle.target.toLowerCase() === deployer : null,
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
      if (match[3].toLowerCase().includes(deployer.slice(2)) && !seen.has(address.toLowerCase())) {
        seen.add(address.toLowerCase());
        deployerDependent.push({ address, contract: match[2] });
      }
    }
  }

  const supportingFiles: Record<string, string> = {};
  for (const relativePath of SUPPORTING_BUNDLE_FILES) {
    const filePath = path.join(bundleDirectory, relativePath);
    if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) supportingFiles[relativePath] = fileSha256(filePath);
  }
  const ecosystemToml = fs.readFileSync(path.join(bundleDirectory, "ecosystem.toml"), "utf8");
  const githubRunId = process.env.GITHUB_RUN_ID;
  const metadata: DeployBundleMetadata = {
    schema: DEPLOY_BUNDLE_SCHEMA,
    upgrade: V31_UPGRADE_NAME,
    env: environment,
    protocol_version: {
      old: protocolVersions(ecosystemToml, "old_protocol_version"),
      new: protocolVersions(ecosystemToml, "new_protocol_version"),
    },
    contracts_commit: contractsCommit,
    contracts_worktree_dirty: dirtyResult.status !== 0,
    all_contracts_hashes_sha256: fileSha256(path.join(REPO_ROOT, "AllContractsHashes.json")),
    l1: {
      chain_id: optionalTomlInteger(permanentValues, "l1_chain_id") ?? null,
      forked_at_block: process.env.FORKED_AT_BLOCK ? Number(process.env.FORKED_AT_BLOCK) : null,
    },
    deployer_address: process.env.DEPLOYER_ADDR ?? null,
    deployer_dependent_deployments: deployerDependent,
    zk_governance_commit: process.env.ZK_GOVERNANCE_COMMIT ?? null,
    toolchain: {
      forge: captureCommand("forge", ["--version"], undefined, "unknown").split("\n")[0],
      rustc: captureCommand("rustc", ["--version"], undefined, "unknown"),
      foundry_zksync: process.env.ZKSYNC_FOUNDRY_VERSION ?? null,
    },
    generated_by: githubRunId
      ? {
          workflow_run: `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${githubRunId}`,
          runner_os: process.env.RUNNER_OS ?? null,
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
