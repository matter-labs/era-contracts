/// Checks that the protocol version of every live CTM has a release tag on a `release/*` branch. The policy it enforces
/// is in `docs/release-tags.md`.
///
/// Usage: yarn check-release-tags [--require-onchain]
/// Reads L1_RPC_URL_MAINNET and L1_RPC_URL_SEPOLIA. An environment whose RPC is not set is skipped, unless
/// --require-onchain is passed (the scheduled workflow passes it).

import { execFileSync } from "child_process";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as toml from "toml";

// eslint-disable-next-line @typescript-eslint/no-var-requires
const CTM_ABI = require("../zkstack-out/IChainTypeManager.sol/IChainTypeManager.json");
// eslint-disable-next-line @typescript-eslint/no-var-requires
const BRIDGEHUB_ABI = require("../zkstack-out/L1Bridgehub.sol/L1Bridgehub.json");

const REPO_ROOT = path.join(__dirname, "..", "..");
const PERMANENT_VALUES_DIR = path.join(__dirname, "..", "upgrade-envs", "permanent-values");
const REMOTE = "origin";
const RELEASE_BRANCH_PREFIX = "release/";
const MAIN_BRANCH = "main";

// The environments in `upgrade-envs/permanent-values` whose CTMs must run tagged versions. Stage runs release
// candidates, so it is not checked.
const ENVIRONMENTS = ["mainnet", "adi", "testnet", "testnet3"];

const MAINNET_CHAIN_ID = 1;
const SEPOLIA_CHAIN_ID = 11155111;
const RPC_ENV_VARS: Record<number, string> = {
  [MAINNET_CHAIN_ID]: "L1_RPC_URL_MAINNET",
  [SEPOLIA_CHAIN_ID]: "L1_RPC_URL_SEPOLIA",
};

// GitHub's subject for a PR merged with a merge commit; the group is the PR's head branch.
const MERGE_SUBJECT_PATTERN = /^Merge pull request #\d+ from [^/]+\/(.+)$/;

interface PermanentValues {
  l1_chain_id: number;
  core_contracts: { bridgehub_proxy_addr: string };
  ctm_contracts: { ctms: { proxy: string; is_zk_sync_os?: boolean }[] };
}

const errors: string[] = [];
const warnings: string[] = [];
const passed: string[] = [];

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

// A `release/*` branch's head, and the base its own commits are not on: main for a live branch. A branch merged into
// main with a merge commit and since deleted is the merge's second parent, with the first parent as its base. Without
// the base, a commit main had when the branch was cut would count as a release commit.
interface ReleaseHead {
  head: string;
  base: string;
}

function releaseHeads(): ReleaseHead[] {
  const main = `refs/remotes/${REMOTE}/${MAIN_BRANCH}`;
  const branches = git("for-each-ref", "--format=%(refname)", `refs/remotes/${REMOTE}/${RELEASE_BRANCH_PREFIX}`)
    .split("\n")
    .filter((ref) => ref)
    .map((ref) => ({ head: ref, base: main }));
  const merged = git("log", "--first-parent", "--merges", "--format=%H %s", main)
    .split("\n")
    .filter((line) => {
      const subject = line.split(" ").slice(1).join(" ");
      return MERGE_SUBJECT_PATTERN.exec(subject)?.[1].startsWith(RELEASE_BRANCH_PREFIX);
    })
    .map((line) => line.split(" ")[0])
    .map((merge) => ({ head: `${merge}^2`, base: `${merge}^1` }));
  return [...branches, ...merged];
}

function onReleaseBranch(_commit: string, _releaseHeads: ReleaseHead[]): boolean {
  return _releaseHeads.some(
    ({ head, base }) =>
      gitSucceeds("merge-base", "--is-ancestor", _commit, head) &&
      !gitSucceeds("merge-base", "--is-ancestor", _commit, base)
  );
}

// `era-v<version>` releases the Era CTM, `v<version>` the ZKsync OS CTM, whose releases were `zkos-v<version>` before.
function tagNames(_version: string, _isZKsyncOS: boolean): string[] {
  return _isZKsyncOS ? [`v${_version}`, `zkos-v${_version}`] : [`era-v${_version}`];
}

async function checkEnvironment(_env: string, _requireOnchain: boolean, _releaseHeads: ReleaseHead[]) {
  const values: PermanentValues = toml.parse(fs.readFileSync(path.join(PERMANENT_VALUES_DIR, `${_env}.toml`), "utf8"));
  const rpcEnvVar = RPC_ENV_VARS[values.l1_chain_id];
  if (!rpcEnvVar) {
    errors.push(`${_env}: no RPC for L1 chain ${values.l1_chain_id}`);
    return;
  }
  const rpcUrl = process.env[rpcEnvVar];
  if (!rpcUrl) {
    (_requireOnchain ? errors : warnings).push(`${_env}: ${rpcEnvVar} is not set, not checked`);
    return;
  }
  try {
    await checkCtms(_env, values, new ethers.providers.JsonRpcProvider(rpcUrl), _releaseHeads);
  } catch (error) {
    // An unreachable RPC or a failed call is reported, not mistaken for a missing tag. The RPC URL may hold a key.
    const message = error instanceof Error ? error.message : String(error);
    errors.push(`${_env}: on-chain check failed: ${message.split(rpcUrl).join(rpcEnvVar)}`);
  }
}

async function checkCtms(
  _env: string,
  _values: PermanentValues,
  _provider: ethers.providers.Provider,
  _releaseHeads: ReleaseHead[]
) {
  // Only a mainnet CTM fails the run: some testnet versions released before this policy have no tag.
  const failures = _values.l1_chain_id == MAINNET_CHAIN_ID ? errors : warnings;
  const listed = new Map(_values.ctm_contracts.ctms.map((ctm) => [ctm.proxy.toLowerCase(), ctm]));

  const bridgehub = new ethers.Contract(_values.core_contracts.bridgehub_proxy_addr, BRIDGEHUB_ABI, _provider);
  const ctms = new Set<string>();
  for (const chainId of await bridgehub.getAllZKChainChainIDs()) {
    ctms.add(await bridgehub.chainTypeManager(chainId));
  }

  for (const ctm of ctms) {
    const entry = listed.get(ctm.toLowerCase());
    if (!entry) {
      failures.push(`${_env}: CTM ${ctm} has chains in the Bridgehub but is not in permanent-values/${_env}.toml`);
      continue;
    }
    const contract = new ethers.Contract(ctm, CTM_ABI, _provider);
    // The file sets `is_zk_sync_os` for CTMs older than v0.31, which have no `isZKsyncOS()`.
    const isZKsyncOS: boolean = entry.is_zk_sync_os ?? (await contract.isZKsyncOS());
    const [major, minor, patch] = await contract.getSemverProtocolVersion();
    const version = `${major}.${minor}.${patch}`;
    const label = `${_env} ${isZKsyncOS ? "ZKsync OS" : "Era"} CTM ${ctm} at ${version}`;

    const names = tagNames(version, isZKsyncOS);
    const tags = names.filter((name) => gitSucceeds("rev-parse", "--verify", "--quiet", `refs/tags/${name}`));
    if (!tags.length) {
      failures.push(`${label}: no \`${names[0]}\` tag`);
      continue;
    }
    const released = tags.find((tag) => onReleaseBranch(git("rev-parse", `refs/tags/${tag}^{commit}`), _releaseHeads));
    if (released) {
      passed.push(`${label}: \`${released}\``);
    } else {
      failures.push(`${label}: \`${tags.join("`, `")}\` not on a \`${RELEASE_BRANCH_PREFIX}*\` branch`);
    }
  }
}

function report() {
  const lines = ["## Release tags", ""];
  lines.push(errors.length ? `**${errors.length} error(s)**` : "**All checks passed**", "");
  lines.push(...errors.map((error) => `- ❌ ${error}`));
  lines.push(...warnings.map((warning) => `- ⚠️ ${warning}`));
  lines.push(...passed.map((line) => `- ✅ ${line}`));
  const text = lines.join("\n");
  console.log(text);
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, text + "\n");
  }
}

async function main() {
  const requireOnchain = process.argv.includes("--require-onchain");
  const heads = releaseHeads();
  for (const env of ENVIRONMENTS) {
    await checkEnvironment(env, requireOnchain, heads);
  }
  report();
  if (errors.length) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
