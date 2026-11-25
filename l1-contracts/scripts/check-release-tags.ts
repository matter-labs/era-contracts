/// Checks that the protocol version of every live CTM has a release tag. The policy it enforces is in
/// `docs/release-tags.md`.
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

// The environments in `upgrade-envs/permanent-values` whose CTMs must run tagged versions.
const ENVIRONMENTS = ["stage", "testnet", "testnet3", "mainnet", "adi"];

const MAINNET_CHAIN_ID = 1;
const SEPOLIA_CHAIN_ID = 11155111;
const RPC_ENV_VARS: Record<number, string> = {
  [MAINNET_CHAIN_ID]: "L1_RPC_URL_MAINNET",
  [SEPOLIA_CHAIN_ID]: "L1_RPC_URL_SEPOLIA",
};

interface PermanentValues {
  l1_chain_id: number;
  core_contracts: { bridgehub_proxy_addr: string };
  ctm_contracts: { ctms: { proxy: string; is_zk_sync_os?: boolean }[] };
}

const errors: string[] = [];
const warnings: string[] = [];
const passed: string[] = [];

function tagExists(_name: string): boolean {
  try {
    execFileSync("git", ["rev-parse", "--verify", "--quiet", `refs/tags/${_name}`], {
      cwd: REPO_ROOT,
      stdio: "ignore",
    });
    return true;
  } catch {
    return false;
  }
}

// `era-v<version>` releases the Era CTM, `v<version>` the ZKsync OS CTM, whose releases were `zkos-v<version>` before.
function tagNames(_version: string, _isZKsyncOS: boolean): string[] {
  return _isZKsyncOS ? [`v${_version}`, `zkos-v${_version}`] : [`era-v${_version}`];
}

async function checkEnvironment(_env: string, _requireOnchain: boolean) {
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
    await checkCtms(_env, values, new ethers.providers.JsonRpcProvider(rpcUrl));
  } catch (error) {
    // An unreachable RPC or a failed call is reported, not mistaken for a missing tag. The RPC URL may hold a key.
    const message = error instanceof Error ? error.message : String(error);
    errors.push(`${_env}: on-chain check failed: ${message.split(rpcUrl).join(rpcEnvVar)}`);
  }
}

async function checkCtms(_env: string, _values: PermanentValues, _provider: ethers.providers.Provider) {
  const listed = new Map(_values.ctm_contracts.ctms.map((ctm) => [ctm.proxy.toLowerCase(), ctm]));

  const bridgehub = new ethers.Contract(_values.core_contracts.bridgehub_proxy_addr, BRIDGEHUB_ABI, _provider);
  const ctms = new Set<string>();
  for (const chainId of await bridgehub.getAllZKChainChainIDs()) {
    ctms.add(await bridgehub.chainTypeManager(chainId));
  }

  for (const ctm of ctms) {
    const entry = listed.get(ctm.toLowerCase());
    if (!entry) {
      errors.push(`${_env}: CTM ${ctm} has chains in the Bridgehub but is not in permanent-values/${_env}.toml`);
      continue;
    }
    const contract = new ethers.Contract(ctm, CTM_ABI, _provider);
    // The file sets `is_zk_sync_os` for CTMs older than v0.31, which have no `isZKsyncOS()`.
    const isZKsyncOS: boolean = entry.is_zk_sync_os ?? (await contract.isZKsyncOS());
    const [major, minor, patch] = await contract.getSemverProtocolVersion();
    const version = `${major}.${minor}.${patch}`;
    const label = `${_env} ${isZKsyncOS ? "ZKsync OS" : "Era"} CTM ${ctm} at ${version}`;

    const names = tagNames(version, isZKsyncOS);
    const tag = names.find(tagExists);
    if (tag) {
      passed.push(`${label}: \`${tag}\``);
    } else {
      errors.push(`${label}: no \`${names[0]}\` tag`);
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
  for (const env of ENVIRONMENTS) {
    await checkEnvironment(env, requireOnchain);
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
