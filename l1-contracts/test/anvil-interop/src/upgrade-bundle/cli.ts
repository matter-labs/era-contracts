import * as path from "path";
import { parseArgs } from "util";
import { packDeployBundle, verifyBundleIntegrity } from "./bundle";
import { DEFAULT_GATEWAY_RPC_URL, DEFAULT_ZK_GOVERNANCE_COMMIT, formatError, parseInteger } from "./common";
import { restoreCanonicalDefaultAccountArtifact } from "./default-account";
import { regenerateAndVerify, replayBundleAndVerify } from "./flows";
import type { ReplayMode } from "./flows";

const USAGE = `usage: yarn bundle <command> [options]

commands:
  regen <environment> --fork-url <l1-rpc> --deployer <address> [--fork-block <n>]
        [--gw-rpc-url <url>] [--zk-governance-commit <sha>] [--foundry-zksync-version <v>]
  pack <environment> [--deployer <address>] [--forked-at-block <n>] [--zk-governance-commit <sha>]
        [--foundry-zksync-version <v>] [--out <dir>]
  replay --bundle <dir> --fork-url <l1-rpc>             rehearse on a fresh fork
  replay --bundle <dir> --rpc <l1-rpc> --key <0xhex>    broadcast the deployer's bundles for real
  replay --bundle <dir> --rpc <l1-rpc> --verify-only    PUVT a chain the bundle was already broadcast to
        [--gw-rpc-url <url>] [--zk-governance-commit <sha>]
  verify <deploy-bundle-directory>
  restore-default-account <artifact.json> <environment.toml> <AllContractsHashes.json>`;

function usage(message?: string): never {
  throw new Error(message ? `${message}\n\n${USAGE}` : USAGE);
}

/** CI passes blanks for unset optional inputs, so an empty flag value means "not given". */
function given(value: string | undefined): string | undefined {
  return value || undefined;
}

function positional(args: string[], count: number, command: string): string[] {
  if (args.length !== count) usage(`bundle ${command} expects ${count} positional argument(s)`);
  return args;
}

const STRING = { type: "string" } as const;
const VERIFY_OPTIONS = { "gw-rpc-url": STRING, "zk-governance-commit": STRING } as const;

function replayMode(values: { "fork-url"?: string; rpc?: string; key?: string; "verify-only"?: boolean }): ReplayMode {
  const forkUrl = given(values["fork-url"]);
  const rpcUrl = given(values.rpc);
  const deployerKey = given(values.key);
  const verifyOnly = values["verify-only"] === true;
  if (forkUrl && !rpcUrl && !deployerKey && !verifyOnly) return { kind: "rehearse", forkUrl };
  if (rpcUrl && !forkUrl && deployerKey && !verifyOnly) return { kind: "broadcast", rpcUrl, deployerKey };
  if (rpcUrl && !forkUrl && !deployerKey && verifyOnly) return { kind: "verify", rpcUrl };
  return usage(
    "bundle replay takes exactly one of: --fork-url <l1-rpc> | --rpc <l1-rpc> --key <0xhex> | --rpc <l1-rpc> --verify-only"
  );
}

async function main(argv: string[]): Promise<void> {
  const [command, ...args] = argv;
  switch (command) {
    case "help":
    case "--help":
    case "-h":
      console.log(USAGE);
      return;
    case "regen": {
      const { values, positionals } = parseArgs({
        args,
        options: {
          "fork-url": STRING,
          deployer: STRING,
          "fork-block": STRING,
          "foundry-zksync-version": STRING,
          ...VERIFY_OPTIONS,
        },
        allowPositionals: true,
      });
      const [environment] = positional(positionals, 1, command);
      await regenerateAndVerify({
        environment,
        forkUrl: given(values["fork-url"]) ?? usage("bundle regen requires --fork-url"),
        deployer: given(values.deployer) ?? usage("bundle regen requires --deployer"),
        forkBlock: parseInteger(given(values["fork-block"]), "--fork-block"),
        gatewayRpcUrl: given(values["gw-rpc-url"]) ?? DEFAULT_GATEWAY_RPC_URL,
        zkGovernanceCommit: given(values["zk-governance-commit"]) ?? DEFAULT_ZK_GOVERNANCE_COMMIT,
        foundryZksyncVersion: given(values["foundry-zksync-version"]),
      });
      return;
    }
    case "pack": {
      const { values, positionals } = parseArgs({
        args,
        options: {
          deployer: STRING,
          "forked-at-block": STRING,
          "zk-governance-commit": STRING,
          "foundry-zksync-version": STRING,
          out: STRING,
        },
        allowPositionals: true,
      });
      const [environment] = positional(positionals, 1, command);
      packDeployBundle(environment, {
        bundleDirectory: given(values.out),
        provenance: {
          deployerAddress: given(values.deployer),
          forkedAtBlock: parseInteger(given(values["forked-at-block"]), "--forked-at-block"),
          zkGovernanceCommit: given(values["zk-governance-commit"]),
          foundryZksyncVersion: given(values["foundry-zksync-version"]),
        },
      });
      return;
    }
    case "replay": {
      const { values } = parseArgs({
        args,
        options: {
          bundle: STRING,
          "fork-url": STRING,
          rpc: STRING,
          key: STRING,
          "verify-only": { type: "boolean" },
          ...VERIFY_OPTIONS,
        },
      });
      await replayBundleAndVerify({
        bundleDirectory: path.resolve(given(values.bundle) ?? usage("bundle replay requires --bundle")),
        mode: replayMode(values),
        gatewayRpcUrl: given(values["gw-rpc-url"]),
        zkGovernanceCommit: given(values["zk-governance-commit"]),
      });
      return;
    }
    case "verify": {
      const [bundleDirectory] = positional(args, 1, command);
      verifyBundleIntegrity(bundleDirectory);
      return;
    }
    case "restore-default-account": {
      const [artifactPath, environmentPath, hashesPath] = positional(args, 3, command);
      restoreCanonicalDefaultAccountArtifact(artifactPath, environmentPath, hashesPath);
      return;
    }
    default:
      usage(command === undefined ? undefined : `unknown bundle command: ${command}`);
  }
}

void main(process.argv.slice(2)).catch((error) => {
  console.error(formatError(error));
  process.exitCode = 1;
});
