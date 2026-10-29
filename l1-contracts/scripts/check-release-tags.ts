/// Checks the release tags and the live deployments recorded in `release-tags.json` against git and
/// the chain state. The policy it enforces is in `docs/release-tags.md`.
///
/// Usage: yarn check-release-tags [--require-onchain]
/// The on-chain part reads L1_RPC_URL_MAINNET and L1_RPC_URL_SEPOLIA. Without them it is skipped,
/// unless --require-onchain is passed (the scheduled workflow passes it).

import { execFileSync } from "child_process";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

// Both the CTM and a chain's diamond (IGetters) expose this.
const SEMVER_ABI = ["function getSemverProtocolVersion() view returns (uint32, uint32, uint32)"];
const BRIDGEHUB_ABI = [
  "function chainTypeManager(uint256 chainId) view returns (address)",
  "function getZKChain(uint256 chainId) view returns (address)",
];

const REPO_ROOT = path.join(__dirname, "..", "..");
const MANIFEST_PATH = path.join(REPO_ROOT, "release-tags.json");
const REMOTE = "origin";
const RELEASE_BRANCH_PREFIX = "release/";

// Every tag that matches this is a release tag and must be recorded in the manifest.
const RELEASE_TAG_PATTERN = /^(v\d|era-v\d|zkos-v?\d|zip-\d)/;
// `v<version>` releases the ZKsync OS CTM, `era-v<version>` the Era CTM.
const VERSION_TAG_PATTERN = /^(era-)?v(\d+\.\d+\.\d+)$/;
// `zip-<n>` marks the commit that produced governance proposal ZIP-<n>'s calldata.
const PROPOSAL_TAG_PATTERN = /^zip-\d+$/;

const FLAVOURS = ["era", "zksync-os"] as const;
type Flavour = (typeof FLAVOURS)[number];

const RPC_ENV_VARS: Record<string, string> = {
  mainnet: "L1_RPC_URL_MAINNET",
  sepolia: "L1_RPC_URL_SEPOLIA",
};

interface ReleaseTag {
  name: string;
  commit: string;
  branch: string;
  genesis: Partial<Record<Flavour, string>>;
}

interface Deployment {
  name: string;
  l1: string;
  flavour: Flavour;
  bridgehub: string;
  ctm: string;
  protocolVersion: string;
  tag?: string;
  chains: number[];
}

interface Manifest {
  legacyTags: string[];
  tags: ReleaseTag[];
  deployments: Deployment[];
}

const errors: string[] = [];
const warnings: string[] = [];

function git(..._args: string[]): string {
  return execFileSync("git", _args, { cwd: REPO_ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function gitSucceeds(..._args: string[]): boolean {
  try {
    git(..._args);
    return true;
  } catch {
    return false;
  }
}

function genesisVersion(_commit: string, _flavour: Flavour): string | undefined {
  const file = `configs/genesis/${_flavour}/latest.json`;
  if (!gitSucceeds("cat-file", "-e", `${_commit}:${file}`)) {
    return undefined;
  }
  const { major, minor, patch } = JSON.parse(git("show", `${_commit}:${file}`)).protocol_semantic_version;
  return `${major}.${minor}.${patch}`;
}

function checkTags(_manifest: Manifest) {
  const recorded = new Map(_manifest.tags.map((tag) => [tag.name, tag]));
  const legacy = new Set(_manifest.legacyTags);
  if (recorded.size != _manifest.tags.length) {
    errors.push("release-tags.json lists a tag twice");
  }
  for (const name of legacy) {
    if (recorded.has(name)) {
      errors.push(`\`${name}\` is both a legacy tag and a checked tag`);
    }
  }

  for (const name of git("tag", "--list")
    .split("\n")
    .filter((tag) => RELEASE_TAG_PATTERN.test(tag))) {
    if (!recorded.has(name) && !legacy.has(name)) {
      errors.push(`tag \`${name}\` is not recorded in release-tags.json`);
    }
  }

  for (const tag of _manifest.tags) {
    const versionMatch = VERSION_TAG_PATTERN.exec(tag.name);
    if (!versionMatch && !PROPOSAL_TAG_PATTERN.test(tag.name)) {
      errors.push(`\`${tag.name}\`: name is neither \`v<x.y.z>\`, \`era-v<x.y.z>\` nor \`zip-<n>\``);
    }
    if (!gitSucceeds("rev-parse", "--verify", "--quiet", `refs/tags/${tag.name}`)) {
      errors.push(`\`${tag.name}\`: tag does not exist`);
      continue;
    }
    const commit = git("rev-parse", `refs/tags/${tag.name}^{commit}`);
    if (commit != tag.commit) {
      errors.push(`\`${tag.name}\`: points at ${commit}, release-tags.json records ${tag.commit}`);
    }
    if (!tag.branch.startsWith(RELEASE_BRANCH_PREFIX)) {
      errors.push(`\`${tag.name}\`: branch \`${tag.branch}\` is not a \`${RELEASE_BRANCH_PREFIX}*\` branch`);
    } else if (!gitSucceeds("merge-base", "--is-ancestor", commit, `refs/remotes/${REMOTE}/${tag.branch}`)) {
      errors.push(`\`${tag.name}\`: ${commit} is not on \`${tag.branch}\``);
    }
    for (const flavour of FLAVOURS) {
      const expected = tag.genesis[flavour];
      const actual = genesisVersion(commit, flavour);
      if (expected != actual) {
        errors.push(
          `\`${tag.name}\`: ${flavour} genesis is ${actual ?? "missing"}, release-tags.json says ${expected}`
        );
      }
    }
    if (versionMatch) {
      const flavour: Flavour = versionMatch[1] ? "era" : "zksync-os";
      if (tag.genesis[flavour] != versionMatch[2]) {
        errors.push(
          `\`${tag.name}\`: ${flavour} genesis is ${tag.genesis[flavour]}, the tag name says ${versionMatch[2]}`
        );
      }
    }
  }
}

async function semver(_contract: ethers.Contract): Promise<string> {
  const [major, minor, patch] = await _contract.getSemverProtocolVersion();
  return `${major}.${minor}.${patch}`;
}

async function checkDeployments(_manifest: Manifest, _requireOnchain: boolean) {
  const recorded = new Map(_manifest.tags.map((tag) => [tag.name, tag]));
  const providers = new Map<string, ethers.providers.JsonRpcProvider>();

  for (const deployment of _manifest.deployments) {
    const label = `${deployment.name} (${deployment.ctm})`;
    if (deployment.tag) {
      const tag = recorded.get(deployment.tag);
      if (!tag) {
        errors.push(`${label}: tag \`${deployment.tag}\` is not a checked tag in release-tags.json`);
      } else if (tag.genesis[deployment.flavour] != deployment.protocolVersion) {
        errors.push(
          `${label}: runs ${deployment.protocolVersion}, but \`${deployment.tag}\` releases ${deployment.flavour} ` +
            `${tag.genesis[deployment.flavour]}`
        );
      }
    } else {
      warnings.push(`${label}: ${deployment.protocolVersion} has no release tag`);
    }

    const rpcEnvVar = RPC_ENV_VARS[deployment.l1];
    if (!rpcEnvVar) {
      errors.push(`${label}: unknown L1 \`${deployment.l1}\``);
      continue;
    }
    const rpcUrl = process.env[rpcEnvVar];
    if (!rpcUrl) {
      (_requireOnchain ? errors : warnings).push(`${label}: ${rpcEnvVar} is not set, on-chain state not checked`);
      continue;
    }
    if (!providers.has(rpcUrl)) {
      providers.set(rpcUrl, new ethers.providers.JsonRpcProvider(rpcUrl));
    }
    const provider = providers.get(rpcUrl)!;

    try {
      await checkOnchain(deployment, label, provider);
    } catch (error) {
      // An unreachable RPC or a failed call is reported, not mistaken for a mismatch.
      errors.push(`${label}: on-chain check failed: ${error instanceof Error ? error.message : error}`);
    }
  }
}

async function checkOnchain(_deployment: Deployment, _label: string, _provider: ethers.providers.Provider) {
  // Only a mainnet CTM's version drift fails the run: the Sepolia CTMs move with every stage and testnet upgrade.
  const drift = _deployment.l1 == "mainnet" ? errors : warnings;
  const ctmVersion = await semver(new ethers.Contract(_deployment.ctm, SEMVER_ABI, _provider));
  if (ctmVersion != _deployment.protocolVersion) {
    drift.push(`${_label}: CTM is at ${ctmVersion}, release-tags.json says ${_deployment.protocolVersion}`);
  }

  const bridgehub = new ethers.Contract(_deployment.bridgehub, BRIDGEHUB_ABI, _provider);
  for (const chainId of _deployment.chains) {
    const chainCtm: string = await bridgehub.chainTypeManager(chainId);
    if (chainCtm.toLowerCase() != _deployment.ctm.toLowerCase()) {
      errors.push(`${_label}: chain ${chainId} is registered under CTM ${chainCtm}`);
      continue;
    }
    const diamond = new ethers.Contract(await bridgehub.getZKChain(chainId), SEMVER_ABI, _provider);
    const chainVersion = await semver(diamond);
    // A chain upgrades after its CTM, so a chain that lags is reported but does not fail the run.
    if (chainVersion != _deployment.protocolVersion) {
      warnings.push(
        `${_label}: chain ${chainId} is at ${chainVersion}, release-tags.json says ${_deployment.protocolVersion}`
      );
    }
  }
}

function report() {
  const lines = ["## Release tags and deployments", ""];
  lines.push(errors.length ? `**${errors.length} error(s)**` : "**All checks passed**", "");
  lines.push(...errors.map((error) => `- ❌ ${error}`));
  lines.push(...warnings.map((warning) => `- ⚠️ ${warning}`));
  const text = lines.join("\n");
  console.log(text);
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, text + "\n");
  }
}

async function main() {
  const manifest: Manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8"));
  checkTags(manifest);
  await checkDeployments(manifest, process.argv.includes("--require-onchain"));
  report();
  if (errors.length) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
