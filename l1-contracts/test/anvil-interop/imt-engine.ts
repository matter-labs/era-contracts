/**
 * IMT engine CLI.
 *
 * Given an RPC URL and an item, produces the proofs the AtomicFlowEscrow needs against the per-chain
 * Indexed Merkle Tree and the L1 historical global IMT.
 *
 * Subcommands:
 *   value          --flow-id <0x> --spec-hash <0x>
 *                  Compute the commit value for a (flowId, specHash).
 *
 *   low-nullifier  --l2-rpc <url> --tree <addr> --value <0x|dec> [--l2-block <n>]
 *                  Low-nullifier index to pass to commitPart when inserting `value`.
 *
 *   full-proof     --l1-rpc <url> --l2-rpc <url> --tree <addr> --registry <addr>
 *                  --chain-id <n> --value <0x|dec> --l1-block <n> [--l2-block <n>]
 *                  Inclusion proof (ImtInclusionProof JSON) for AtomicFlowEscrow.finalize.
 *
 *   non-inclusion  --l1-rpc <url> --l2-rpc <url> --tree <addr> --registry <addr>
 *                  --chain-id <n> --value <0x|dec> --l1-block-before <n> --l1-block-after <n> [--l2-block <n>]
 *                  O(log n) non-inclusion proof (ImtNonInclusionProof JSON) for AtomicFlowEscrow.refund.
 */

import { providers } from "ethers";
import {
  buildInclusionProof,
  buildNonInclusionProof,
  commitValue,
  commitmentTree,
  globalRegistry,
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
      const l1Provider = new providers.JsonRpcProvider(require_(flags, "l1-rpc"));
      const l2Provider = new providers.JsonRpcProvider(require_(flags, "l2-rpc"));
      const proof = await buildInclusionProof({
        l2Tree: commitmentTree(require_(flags, "tree"), l2Provider),
        registry: globalRegistry(require_(flags, "registry"), l1Provider),
        chainId: require_(flags, "chain-id"),
        value: require_(flags, "value"),
        l1Block: Number(require_(flags, "l1-block")),
        l2BlockTag: flags["l2-block"] ? Number(flags["l2-block"]) : undefined,
      });
      print(proof);
      break;
    }

    case "non-inclusion": {
      const l1Provider = new providers.JsonRpcProvider(require_(flags, "l1-rpc"));
      const l2Provider = new providers.JsonRpcProvider(require_(flags, "l2-rpc"));
      const proof = await buildNonInclusionProof({
        l2Tree: commitmentTree(require_(flags, "tree"), l2Provider),
        registry: globalRegistry(require_(flags, "registry"), l1Provider),
        chainId: require_(flags, "chain-id"),
        value: require_(flags, "value"),
        l1BlockBefore: Number(require_(flags, "l1-block-before")),
        l1BlockAfter: Number(require_(flags, "l1-block-after")),
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
