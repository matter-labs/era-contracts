/**
 * IMT engine library — the off-chain counterpart of the on-chain atomic-interop proof system.
 *
 * It reconstructs, from event logs, the per-chain interop IMT ({L2InteropCommitmentTree}) and the
 * L1 global interop IMT ({GlobalInteropIMT}), and produces the Merkle proofs the
 * {AtomicFlowEscrow} verifies:
 *
 *   - an inclusion proof that a commit leaf is in a chain's IMT and that the chain's IMT root is in
 *     a global root the L2 imported in time;
 *   - the data needed for a non-inclusion proof on the timeout/refund path.
 *
 * Both trees are complete binary Merkle trees hashing with keccak256(left || right) and padding
 * empty slots with the cascading zero of {IMT_EMPTY_LEAF} = bytes32(0). {DynamicIncrementalMerkle}
 * (chain IMT) and {FullMerkle} (global tree) yield identical roots/paths for the same leaves, so a
 * single tree builder serves both.
 */

import type { providers } from "ethers";
import { BigNumber, Contract, ethers, utils } from "ethers";
import { getAbi } from "../core/contracts";

/** Empty-leaf / zero value shared by every IMT and the global tree. */
export const IMT_EMPTY_LEAF: string = ethers.constants.HashZero;

/** Domain tag for commit leaves: bytes4(keccak256("AtomicInterop.commit.v1")). */
export const ATOMIC_COMMIT_LEAF_TAG: string = utils
  .keccak256(utils.toUtf8Bytes("AtomicInterop.commit.v1"))
  .slice(0, 10);

export interface FlowLeg {
  chainId: BigNumber | number | string;
  token: string;
  amount: BigNumber | number | string;
  payer: string;
  payee: string;
}

export interface InclusionProof {
  chainId: string;
  chainImtRoot: string;
  imtLeafIndex: number;
  imtProof: string[];
  globalLeafIndex: number;
  globalProof: string[];
  l1BlockNumber: number;
}

export interface NonInclusionProof {
  chainId: string;
  chainImtRoot: string;
  globalLeafIndex: number;
  l1BlockNumberBeforeDeadline: number;
  globalProofG1: string[];
  l1BlockNumberAfterDeadline: number;
  globalProofG2: string[];
  leaves: string[];
}

// ── Leaf / id derivations (must match AtomicInteropProof / AtomicFlowEscrow) ──────────────

export function commitLeaf(flowId: string, specHash: string): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(["bytes4", "bytes32", "bytes32"], [ATOMIC_COMMIT_LEAF_TAG, flowId, specHash])
  );
}

export function globalLeaf(chainId: BigNumber | number | string, chainImtRoot: string): string {
  return utils.keccak256(utils.solidityPack(["bytes32", "uint256"], [chainImtRoot, BigNumber.from(chainId)]));
}

export function specHashOf(leg: FlowLeg): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(
      ["tuple(uint256,address,uint256,address,address)"],
      [[BigNumber.from(leg.chainId), leg.token, BigNumber.from(leg.amount), leg.payer, leg.payee]]
    )
  );
}

export function computeFlowId(
  specHashes: string[],
  chainIds: (BigNumber | number | string)[],
  deadline: number
): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(
      ["bytes32[]", "uint256[]", "uint64"],
      [specHashes, chainIds.map((c) => BigNumber.from(c)), deadline]
    )
  );
}

// ── Complete binary Merkle tree (matches DynamicIncrementalMerkle / FullMerkle) ───────────

function hashPair(left: string, right: string): string {
  return utils.keccak256(utils.concat([left, right]));
}

interface BuiltTree {
  root: string;
  levels: string[][];
  zeros: string[];
}

/** Builds a complete binary tree from an ordered leaf set, padding with the zero cascade. */
export function buildTree(leaves: string[]): BuiltTree {
  if (leaves.length === 0) {
    // Matches DynamicIncrementalMerkle.setup, whose initial root is bytes32(0).
    return { root: IMT_EMPTY_LEAF, levels: [[]], zeros: [IMT_EMPTY_LEAF] };
  }
  const levels: string[][] = [leaves.slice()];
  const zeros: string[] = [IMT_EMPTY_LEAF];
  let level = leaves.slice();
  let h = 0;
  while (level.length > 1) {
    const next: string[] = [];
    for (let i = 0; i < level.length; i += 2) {
      const left = level[i];
      const right = i + 1 < level.length ? level[i + 1] : zeros[h];
      next.push(hashPair(left, right));
    }
    zeros.push(hashPair(zeros[h], zeros[h]));
    level = next;
    levels.push(level);
    h++;
  }
  return { root: level[0], levels, zeros };
}

/** Merkle path (siblings, leaf -> root) for `index` in a built tree. */
export function merklePath(tree: BuiltTree, index: number): string[] {
  const proof: string[] = [];
  const height = tree.levels.length - 1;
  let idx = index;
  for (let level = 0; level < height; level++) {
    const siblingIndex = idx ^ 1;
    const nodes = tree.levels[level];
    proof.push(siblingIndex < nodes.length ? nodes[siblingIndex] : tree.zeros[level]);
    idx >>= 1;
  }
  return proof;
}

// ── Event reconstruction ─────────────────────────────────────────────────────────────────

export function commitmentTree(address: string, provider: providers.Provider): Contract {
  return new Contract(address, getAbi("L2InteropCommitmentTree"), provider);
}

export function globalRegistry(address: string, provider: providers.Provider): Contract {
  return new Contract(address, getAbi("GlobalInteropIMT"), provider);
}

/** Ordered leaf set of a chain's interop IMT as of `blockTag` (latest if undefined). */
export async function reconstructChainImt(
  tree: Contract,
  blockTag?: number
): Promise<{ leaves: string[]; root: string }> {
  const toBlock = blockTag ?? (await tree.provider.getBlockNumber());
  const events = await tree.queryFilter(tree.filters.CommitmentAppended(), 0, toBlock);
  const ordered = events
    .filter((e) => e.args!.index.toNumber() < Number.MAX_SAFE_INTEGER)
    .sort((a, b) => a.args!.index.toNumber() - b.args!.index.toNumber());
  const leaves = ordered.map((e) => e.args!.leaf as string);
  return { leaves, root: buildTree(leaves).root };
}

interface GlobalSnapshot {
  leaves: string[];
  leafIndexOf: Map<string, number>;
  chainRootOf: Map<string, string>;
  root: string;
}

/**
 * Reconstructs the global tree as of L1 block `l1Block`: each registered chain's leaf is
 * `globalLeaf(chainId, latestRoot<=l1Block)`.
 */
export async function reconstructGlobal(registry: Contract, l1Block: number): Promise<GlobalSnapshot> {
  const registered = await registry.queryFilter(registry.filters.ChainRegistered(), 0, l1Block);
  const submitted = await registry.queryFilter(registry.filters.ChainRootSubmitted(), 0, l1Block);

  const leafIndexOf = new Map<string, number>();
  for (const e of registered) {
    leafIndexOf.set(BigNumber.from(e.args!.chainId).toString(), e.args!.leafIndex.toNumber());
  }

  // Latest submitted root per chain, ordered by (block, logIndex).
  const chainRootOf = new Map<string, string>();
  const sorted = submitted.slice().sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
  for (const e of sorted) {
    chainRootOf.set(BigNumber.from(e.args!.chainId).toString(), e.args!.chainImtRoot as string);
  }

  const size = leafIndexOf.size;
  const leaves: string[] = new Array(size).fill(IMT_EMPTY_LEAF);
  for (const [chainId, idx] of leafIndexOf.entries()) {
    const root = chainRootOf.get(chainId);
    if (root) leaves[idx] = globalLeaf(chainId, root);
  }
  return { leaves, leafIndexOf, chainRootOf, root: buildTree(leaves).root };
}

// ── Proof builders ────────────────────────────────────────────────────────────────────────

/**
 * Builds a full inclusion proof for `leaf` in `chainId`'s IMT, anchored to the global root the
 * registry recorded at `l1Block`.
 */
export async function buildInclusionProof(params: {
  l2Tree: Contract;
  registry: Contract;
  chainId: BigNumber | number | string;
  leaf: string;
  l1Block: number;
  l2BlockTag?: number;
}): Promise<InclusionProof> {
  const { l2Tree, registry, chainId, leaf, l1Block, l2BlockTag } = params;

  const { leaves: imtLeaves } = await reconstructChainImt(l2Tree, l2BlockTag);
  const imtIndex = imtLeaves.indexOf(leaf);
  if (imtIndex < 0) throw new Error(`leaf ${leaf} not found in chain ${chainId.toString()} IMT`);
  const imtTree = buildTree(imtLeaves);

  const snapshot = await reconstructGlobal(registry, l1Block);
  const cid = BigNumber.from(chainId).toString();
  const globalLeafIndex = snapshot.leafIndexOf.get(cid);
  if (globalLeafIndex === undefined)
    throw new Error(`chain ${cid} not registered in global tree at L1 block ${l1Block}`);
  const globalTree = buildTree(snapshot.leaves);

  return {
    chainId: cid,
    chainImtRoot: imtTree.root,
    imtLeafIndex: imtIndex,
    imtProof: merklePath(imtTree, imtIndex),
    globalLeafIndex,
    globalProof: merklePath(globalTree, globalLeafIndex),
    l1BlockNumber: l1Block,
  };
}

/**
 * Builds a non-inclusion proof that `leaf` is absent from `chainId`'s IMT across the deadline
 * boundary defined by L1 blocks `l1BlockBefore` (<= deadline) and `l1BlockAfter` (> deadline).
 */
export async function buildNonInclusionProof(params: {
  l2Tree: Contract;
  registry: Contract;
  chainId: BigNumber | number | string;
  leaf: string;
  l1BlockBefore: number;
  l1BlockAfter: number;
  l2BlockTag?: number;
}): Promise<NonInclusionProof> {
  const { l2Tree, registry, chainId, leaf, l1BlockBefore, l1BlockAfter, l2BlockTag } = params;

  const { leaves } = await reconstructChainImt(l2Tree, l2BlockTag);
  if (leaves.indexOf(leaf) >= 0) throw new Error(`leaf ${leaf} IS present; cannot build a non-inclusion proof`);
  const chainImtRoot = buildTree(leaves).root;

  const cid = BigNumber.from(chainId).toString();
  const before = await reconstructGlobal(registry, l1BlockBefore);
  const after = await reconstructGlobal(registry, l1BlockAfter);
  const globalLeafIndex = before.leafIndexOf.get(cid);
  if (globalLeafIndex === undefined) throw new Error(`chain ${cid} not registered at L1 block ${l1BlockBefore}`);

  return {
    chainId: cid,
    chainImtRoot,
    globalLeafIndex,
    l1BlockNumberBeforeDeadline: l1BlockBefore,
    globalProofG1: merklePath(buildTree(before.leaves), globalLeafIndex),
    l1BlockNumberAfterDeadline: l1BlockAfter,
    globalProofG2: merklePath(buildTree(after.leaves), globalLeafIndex),
    leaves,
  };
}
