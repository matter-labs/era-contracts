/**
 * IMT engine CLI.
 *
 * Given an RPC URL and an item, produces the Merkle proof for that item being present in a chain's
 * interop IMT at a given block, and the full proof up to the L1 historical global IMT root.
 *
 * Subcommands:
 *   leaf           --flow-id <0x> --spec-hash <0x>
 *                  Compute the commit leaf for a (flowId, specHash).
 *
 *   chain-proof    --l2-rpc <url> --tree <addr> --leaf <0x> [--l2-block <n>]
 *                  Inclusion proof of a leaf within a chain's interop IMT (chain layer only).
 *
 *   full-proof     --l1-rpc <url> --l2-rpc <url> --tree <addr> --registry <addr>
 *                  --chain-id <n> --leaf <0x> --l1-block <n> [--l2-block <n>]
 *                  Full inclusion proof (chain IMT root -> global root @ L1 block) as the JSON the
 *                  AtomicFlowEscrow.finalize ImtInclusionProof struct expects.
 *
 *   non-inclusion  --l1-rpc <url> --l2-rpc <url> --tree <addr> --registry <addr>
 *                  --chain-id <n> --leaf <0x> --l1-block-before <n> --l1-block-after <n> [--l2-block <n>]
 *                  Non-inclusion proof (timeout/refund path) as the ImtNonInclusionProof JSON.
 *
 * Examples:
 *   npx ts-node imt-engine.ts leaf --flow-id 0x.. --spec-hash 0x..
 *   npx ts-node imt-engine.ts full-proof --l1-rpc http://localhost:8545 --l2-rpc http://localhost:9545 \
 *       --tree 0xTree --registry 0xReg --chain-id 271 --leaf 0xLeaf --l1-block 100
 */

import { providers } from "ethers";
import {
  buildInclusionProof,
  buildNonInclusionProof,
  buildTree,
  commitLeaf,
  commitmentTree,
  globalRegistry,
  merklePath,
  reconstructChainImt,
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
    case "leaf": {
      print({ leaf: commitLeaf(require_(flags, "flow-id"), require_(flags, "spec-hash")) });
      break;
    }

    case "chain-proof": {
      const provider = new providers.JsonRpcProvider(require_(flags, "l2-rpc"));
      const tree = commitmentTree(require_(flags, "tree"), provider);
      const leaf = require_(flags, "leaf");
      const l2Block = flags["l2-block"] ? Number(flags["l2-block"]) : undefined;
      const { leaves } = await reconstructChainImt(tree, l2Block);
      const index = leaves.indexOf(leaf);
      if (index < 0) throw new Error(`leaf ${leaf} not found in the chain IMT`);
      const built = buildTree(leaves);
      print({ leaf, index, chainImtRoot: built.root, imtProof: merklePath(built, index) });
      break;
    }

    case "full-proof": {
      const l1Provider = new providers.JsonRpcProvider(require_(flags, "l1-rpc"));
      const l2Provider = new providers.JsonRpcProvider(require_(flags, "l2-rpc"));
      const proof = await buildInclusionProof({
        l2Tree: commitmentTree(require_(flags, "tree"), l2Provider),
        registry: globalRegistry(require_(flags, "registry"), l1Provider),
        chainId: require_(flags, "chain-id"),
        leaf: require_(flags, "leaf"),
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
        leaf: require_(flags, "leaf"),
        l1BlockBefore: Number(require_(flags, "l1-block-before")),
        l1BlockAfter: Number(require_(flags, "l1-block-after")),
        l2BlockTag: flags["l2-block"] ? Number(flags["l2-block"]) : undefined,
      });
      print(proof);
      break;
    }

    default:
      throw new Error(`unknown command "${command ?? ""}". Use: leaf | chain-proof | full-proof | non-inclusion`);
  }
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
