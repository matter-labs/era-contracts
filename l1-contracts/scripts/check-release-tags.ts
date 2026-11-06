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

// eslint-disable-next-line @typescript-eslint/no-var-requires
const CTM_ABI = require("../zkstack-out/IChainTypeManager.sol/IChainTypeManager.json");
// eslint-disable-next-line @typescript-eslint/no-var-requires
const GETTERS_ABI = require("../zkstack-out/IZKChain.sol/IZKChain.json");
// eslint-disable-next-line @typescript-eslint/no-var-requires
const BRIDGEHUB_ABI = require("../zkstack-out/L1Bridgehub.sol/L1Bridgehub.json");

const REPO_ROOT = path.join(__dirname, "..", "..");
const MANIFEST_FILE = "release-tags.json";
const MANIFEST_PATH = path.join(REPO_ROOT, MANIFEST_FILE);
const REMOTE = "origin";
const RELEASE_BRANCH_PREFIX = "release/";
const MAIN_BRANCH = "main";

// Every tag that matches this is a release tag and must be recorded in the manifest.
const RELEASE_TAG_PATTERN = /^(v\d|era-v\d|zkos-v?\d|zip-\d)/;
// `v<version>` releases the ZKsync OS CTM, `era-v<version>` the Era CTM.
const VERSION_TAG_PATTERN = /^(era-)?v(\d+\.\d+\.\d+)$/;
// `zip-<n>` marks the commit that produced governance proposal ZIP-<n>'s calldata.
const PROPOSAL_TAG_PATTERN = /^zip-\d+$/;
// GitHub's subject for a PR merged with a merge commit; the group is the PR's head branch.
const MERGE_SUBJECT_PATTERN = /^Merge pull request #\d+ from [^/]+\/(.+)$/;

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

// The tag entries main records. A tag's branch is checked only where its entry is added or changed: once recorded, the
// tag pins the commit, and the branch may be squash-merged or deleted.
function tagsOnMain(): Map<string, ReleaseTag> {
  const file = `refs/remotes/${REMOTE}/${MAIN_BRANCH}:${MANIFEST_FILE}`;
  if (!gitSucceeds("cat-file", "-e", file)) {
    return new Map();
  }
  const manifest: Manifest = JSON.parse(git("show", file));
  return new Map(manifest.tags.map((tag) => [tag.name, tag]));
}

// Why `_commit` is not on `_branch`, or undefined if it is. A branch merged into main with a merge commit and then
// deleted still counts: the merge's second parent was the branch's head.
function notOnBranch(_commit: string, _branch: string): string | undefined {
  const ref = `refs/remotes/${REMOTE}/${_branch}`;
  if (gitSucceeds("rev-parse", "--verify", "--quiet", ref)) {
    return gitSucceeds("merge-base", "--is-ancestor", _commit, ref) ? undefined : `${_commit} is not on \`${_branch}\``;
  }
  const merged = git("log", "--first-parent", "--merges", "--format=%H %s", `refs/remotes/${REMOTE}/${MAIN_BRANCH}`)
    .split("\n")
    .some((line) => {
      const [merge, ...subject] = line.split(" ");
      return (
        MERGE_SUBJECT_PATTERN.exec(subject.join(" "))?.[1] == _branch &&
        gitSucceeds("merge-base", "--is-ancestor", _commit, `${merge}^2`)
      );
    });
  return merged
    ? undefined
    : `\`${_branch}\` does not exist, and no merge of it into \`${MAIN_BRANCH}\` contains ${_commit}`;
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

  const onMain = tagsOnMain();
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
    } else if (onMain.get(tag.name)?.commit != tag.commit || onMain.get(tag.name)?.branch != tag.branch) {
      const reason = notOnBranch(commit, tag.branch);
      if (reason) {
        errors.push(`\`${tag.name}\`: ${reason}`);
      }
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
  const ctmVersion = await semver(new ethers.Contract(_deployment.ctm, CTM_ABI, _provider));
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
    const diamond = new ethers.Contract(await bridgehub.getZKChain(chainId), GETTERS_ABI, _provider);
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
