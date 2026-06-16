/**
 * IMT engine CLI (L1-free atomic interop, IMT engine B).
 *
 * Given an RPC URL and an item, produces the proofs the {AtomicFlowEscrow} needs against a chain's
 * per-chain {L2InteropCommitmentTree}. The global IMT + L1 registry are gone: a chain's IMT root is
 * carried by the standard interop-root channel and authenticated via the `(root, timestamp)` L2->L1
 * message, so a proof only references the source chain's tree plus a snapshot timestamp.
 *
 * Subcommands:
 *   value          --flow-id <0x> --spec-hash <0x>
 *                  Compute the commit value for a (flowId, specHash).
 *
 *   low-nullifier  --l2-rpc <url> --tree <addr> --value <0x|dec> [--l2-block <n>]
 *                  Low-nullifier index to pass to commitSend when inserting `value`.
 *
 *   full-proof     --l2-rpc <url> --tree <addr> --chain-id <n> --value <0x|dec>
 *                  --root-timestamp <unix> [--l2-block <n>]
 *                  Inclusion proof (ImtInclusionProof JSON) for AtomicFlowEscrow.authorize.
 *                  `root-timestamp` must be <= the flow deadline.
 *
 *   non-inclusion  --l2-rpc <url> --tree <addr> --chain-id <n> --value <0x|dec>
 *                  --root-timestamp <unix> [--l2-block <n>]
 *                  O(log n) non-inclusion proof (ImtNonInclusionProof JSON) for
 *                  AtomicFlowEscrow.authorizeRefund. `root-timestamp` must be > the flow deadline.
 */

import { providers } from "ethers";
import {
  buildInclusionProof,
  buildNonInclusionProof,
  commitValue,
  commitmentTree,
  lowNullifierIndexFor,
} from "./src/helpers/imt-engine-lib";

function parseFlags(argv: string[]): Record<string, string> {
  const flags: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const val = i + 1 < argv.length && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
      flags[key] = val;
    }
  }
  return flags;
}

function require_(flags: Record<string, string>, key: string): string {
  if (!flags[key]) throw new Error(`missing required flag --${key}`);
  return flags[key];
}

function print(obj: unknown): void {
  // eslint-disable-next-line no-console
  console.log(JSON.stringify(obj, null, 2));
}

async function main(): Promise<void> {
  const [, , command, ...rest] = process.argv;
  const flags = parseFlags(rest);

  switch (command) {
    case "value": {
      print({ value: commitValue(require_(flags, "flow-id"), require_(flags, "spec-hash")) });
      break;
    }

    case "low-nullifier": {
      const provider = new providers.JsonRpcProvider(require_(flags, "l2-rpc"));
      const tree = commitmentTree(require_(flags, "tree"), provider);
      const index = await lowNullifierIndexFor(
        tree,
        require_(flags, "value"),
        flags["l2-block"] ? Number(flags["l2-block"]) : undefined
      );
      print({ lowNullifierIndex: index });
      break;
    }

    case "full-proof": {
      const l2Provider = new providers.JsonRpcProvider(require_(flags, "l2-rpc"));
      const proof = await buildInclusionProof({
        l2Tree: commitmentTree(require_(flags, "tree"), l2Provider),
        chainId: require_(flags, "chain-id"),
        value: require_(flags, "value"),
        rootTimestamp: Number(require_(flags, "root-timestamp")),
        l2BlockTag: flags["l2-block"] ? Number(flags["l2-block"]) : undefined,
      });
      print(proof);
      break;
    }

    case "non-inclusion": {
      const l2Provider = new providers.JsonRpcProvider(require_(flags, "l2-rpc"));
      const proof = await buildNonInclusionProof({
        l2Tree: commitmentTree(require_(flags, "tree"), l2Provider),
        chainId: require_(flags, "chain-id"),
        value: require_(flags, "value"),
        rootTimestamp: Number(require_(flags, "root-timestamp")),
        l2BlockTag: flags["l2-block"] ? Number(flags["l2-block"]) : undefined,
      });
      print(proof);
      break;
    }

    default:
      throw new Error(`unknown command "${command ?? ""}". Use: value | low-nullifier | full-proof | non-inclusion`);
  }
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
