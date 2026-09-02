import * as path from "path";
import { parseArgs } from "util";
import { restoreCanonicalDefaultAccountArtifact } from "./default-account";
import { formatError, parseInteger } from "./file-system";
import { verifyBundleIntegrity } from "./integrity";
import { bundleProvenanceFromEnvironment, packDeployBundle } from "./pack";
import { regenerateAndVerify } from "./regenerate";
import { replayBundleAndVerify } from "./replay";

const COMMANDS = ["pack", "regen", "replay", "restore-default-account", "verify"] as const;
type Command = (typeof COMMANDS)[number];

const USAGE = `usage: yarn bundle <command> [options]

commands:
  pack <environment>
  regen [environment]
  replay --bundle <dir> (--fork-url <l1-rpc> | --rpc <rpc>) [--key <0xhex>] [--verify-only]
  restore-default-account <artifact.json> <environment.toml> <AllContractsHashes.json>
  verify <deploy-bundle-directory>`;

function usage(message?: string): never {
  throw new Error(message ? `${message}\n\n${USAGE}` : USAGE);
}

function isCommand(value: string | undefined): value is Command {
  return COMMANDS.some((command) => command === value);
}

function expectPositionals(args: string[], count: number, command: Command): string[] {
  if (args.length !== count) usage(`bundle ${command} expects ${count} positional argument(s)`);
  return args;
}

async function main(): Promise<void> {
  const [commandName, ...commandArgs] = process.argv.slice(2);
  if (commandName === "help" || commandName === "--help" || commandName === "-h") {
    console.log(USAGE);
    return;
  }
  if (!isCommand(commandName)) usage(commandName ? `unknown bundle command: ${commandName}` : undefined);

  switch (commandName) {
    case "pack": {
      const [environment] = expectPositionals(commandArgs, 1, commandName);
      packDeployBundle(environment, {
        provenance: bundleProvenanceFromEnvironment({
          forkedAtBlock: parseInteger(process.env.FORKED_AT_BLOCK, "FORKED_AT_BLOCK"),
        }),
      });
      return;
    }
    case "regen": {
      if (commandArgs.length > 1) usage("bundle regen accepts at most one environment");
      await regenerateAndVerify(commandArgs[0] ?? "stage");
      return;
    }
    case "replay": {
      const { values } = parseArgs({
        args: commandArgs,
        options: {
          bundle: { type: "string" },
          "fork-url": { type: "string" },
          rpc: { type: "string" },
          key: { type: "string" },
          "verify-only": { type: "boolean", default: false },
        },
        strict: true,
        allowPositionals: false,
      });
      if (!values.bundle) usage("bundle replay requires --bundle");
      if (Boolean(values["fork-url"]) === Boolean(values.rpc)) {
        usage("bundle replay requires exactly one of --fork-url or --rpc");
      }
      await replayBundleAndVerify({
        bundleDirectory: path.resolve(values.bundle),
        forkUrl: values["fork-url"],
        rpcUrl: values.rpc,
        deployerKey: values.key,
        verifyOnly: values["verify-only"],
      });
      return;
    }
    case "restore-default-account": {
      const [artifactPath, environmentPath, hashesPath] = expectPositionals(commandArgs, 3, commandName);
      restoreCanonicalDefaultAccountArtifact(artifactPath, environmentPath, hashesPath);
      return;
    }
    case "verify": {
      const [bundleDirectory] = expectPositionals(commandArgs, 1, commandName);
      verifyBundleIntegrity(bundleDirectory);
    }
  }
}

void main().catch((error) => {
  console.error(formatError(error));
  process.exitCode = 1;
});
