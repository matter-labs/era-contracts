/**
 * IMT engine library — the off-chain counterpart of the on-chain atomic-interop proof system.
 *
 * It reconstructs, from event logs, the per-chain **Indexed Merkle Tree** ({L2InteropCommitmentTree})
 * and the L1 global interop IMT ({GlobalInteropIMT}), and produces the proofs {AtomicFlowEscrow}
 * verifies:
 *
 *   - the low-nullifier index needed to `commitPart` (insert) a value;
 *   - an O(log n) inclusion proof that a commit value is in a chain's IMT and that the chain's IMT
 *     root is in a global root the L2 imported in time;
 *   - an O(log n) non-inclusion proof (low nullifier) for the timeout/refund path.
 *
 * Trees are complete binary Merkle trees hashing with keccak256(left || right) and padding empty
 * slots with the cascading zero of {IMT_EMPTY_LEAF} = bytes32(0). The chain IMT leaf hash is
 * keccak256(abi.encode(uint256 value, uint256 nextValue, uint256 nextIndex)), matching
 * {AtomicInteropProof.indexedLeafHash}.
 */

import type { providers } from "ethers";
import { BigNumber, Contract, ethers, utils } from "ethers";
import { getAbi } from "../core/contracts";

/** Empty-leaf / zero value shared by every tree. */
export const IMT_EMPTY_LEAF: string = ethers.constants.HashZero;

/** Domain tag for commit values: bytes4(keccak256("AtomicInterop.commit.v1")). */
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

/** Indexed-tree leaf. Fields are uint256, serialized as decimal strings. */
export interface IndexedLeaf {
  value: string;
  nextValue: string;
  nextIndex: string;
}

export interface InclusionProof {
  chainId: string;
  chainImtRoot: string;
  leaf: IndexedLeaf;
  imtLeafIndex: number;
  imtProof: string[];
  globalLeafIndex: number;
  globalProof: string[];
  l1BlockNumber: number;
}

export interface NonInclusionProof {
  chainId: string;
  chainImtRoot: string;
  lowLeaf: IndexedLeaf;
  lowLeafIndex: number;
  imtProof: string[];
  globalLeafIndex: number;
  l1BlockNumberBeforeDeadline: number;
  globalProofG1: string[];
  l1BlockNumberAfterDeadline: number;
  globalProofG2: string[];
}

// ── Leaf / id derivations (must match AtomicInteropProof / AtomicFlowEscrow) ──────────────

/** The value inserted into a chain's IMT for a leg, as a 0x bytes32 (also a valid uint256). */
export function commitValue(flowId: string, specHash: string): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(["bytes4", "bytes32", "bytes32"], [ATOMIC_COMMIT_LEAF_TAG, flowId, specHash])
  );
}

export function indexedLeafHash(leaf: IndexedLeaf): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(["uint256", "uint256", "uint256"], [leaf.value, leaf.nextValue, leaf.nextIndex])
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

// ── Complete binary Merkle tree (matches FullMerkle / DynamicIncrementalMerkle) ───────────

function hashPair(left: string, right: string): string {
  return utils.keccak256(utils.concat([left, right]));
}

interface BuiltTree {
  root: string;
  levels: string[][];
  zeros: string[];
}

/** Builds a complete binary tree from an ordered leaf-hash set, padding with the zero cascade. */
export function buildTree(leafHashes: string[]): BuiltTree {
  if (leafHashes.length === 0) {
    return { root: IMT_EMPTY_LEAF, levels: [[]], zeros: [IMT_EMPTY_LEAF] };
  }
  const levels: string[][] = [leafHashes.slice()];
  const zeros: string[] = [IMT_EMPTY_LEAF];
  let level = leafHashes.slice();
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

// ── Contract handles ───────────────────────────────────────────────────────────────────────

export function commitmentTree(address: string, provider: providers.Provider): Contract {
  return new Contract(address, getAbi("L2InteropCommitmentTree"), provider);
}

export function globalRegistry(address: string, provider: providers.Provider): Contract {
  return new Contract(address, getAbi("GlobalInteropIMT"), provider);
}

// ── Chain indexed-tree reconstruction ────────────────────────────────────────────────────

interface ChainImt {
  leaves: IndexedLeaf[]; // index-ordered, includes the head leaf at index 0
  tree: BuiltTree;
  root: string;
}

/** Reconstructs a chain's indexed IMT as of `blockTag` by replaying `LeafUpdated` events. */
export async function reconstructChainImt(tree: Contract, blockTag?: number): Promise<ChainImt> {
  const toBlock = blockTag ?? (await tree.provider.getBlockNumber());
  const events = await tree.queryFilter(tree.filters.LeafUpdated(), 0, toBlock);
  // Order by (block, logIndex); last write per index wins.
  events.sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
  const byIndex = new Map<number, IndexedLeaf>();
  for (const e of events) {
    byIndex.set(e.args!.index.toNumber(), {
      value: e.args!.value.toString(),
      nextValue: e.args!.nextValue.toString(),
      nextIndex: e.args!.nextIndex.toString(),
    });
  }
  const size = byIndex.size;
  const leaves: IndexedLeaf[] = [];
  for (let i = 0; i < size; i++) {
    leaves.push(byIndex.get(i) ?? { value: "0", nextValue: "0", nextIndex: "0" });
  }
  const built = buildTree(leaves.map(indexedLeafHash));
  return { leaves, tree: built, root: built.root };
}

/** Index of the low-nullifier leaf for `value`: `L.value < value < L.nextValue` (or nextValue 0). */
export function findLowNullifierIndex(leaves: IndexedLeaf[], value: string): number {
  const v = BigNumber.from(value);
  for (let i = 0; i < leaves.length; i++) {
    const lv = BigNumber.from(leaves[i].value);
    const nv = BigNumber.from(leaves[i].nextValue);
    if (lv.lt(v) && (nv.isZero() || v.lt(nv))) return i;
  }
  throw new Error(`no low nullifier for value ${value} (already present or empty tree)`);
}

/** Convenience: low-nullifier index for inserting `value` into the current tree (for commitPart). */
export async function lowNullifierIndexFor(tree: Contract, value: string, blockTag?: number): Promise<number> {
  const imt = await reconstructChainImt(tree, blockTag);
  return findLowNullifierIndex(imt.leaves, value);
}

// ── Global tree reconstruction ───────────────────────────────────────────────────────────

interface GlobalSnapshot {
  leaves: string[];
  leafIndexOf: Map<string, number>;
  chainRootOf: Map<string, string>;
  root: string;
}

/** Reconstructs the in-place global tree as of L1 block `l1Block`. */
export async function reconstructGlobal(registry: Contract, l1Block: number): Promise<GlobalSnapshot> {
  const registered = await registry.queryFilter(registry.filters.ChainRegistered(), 0, l1Block);
  const submitted = await registry.queryFilter(registry.filters.ChainRootSubmitted(), 0, l1Block);

  const leafIndexOf = new Map<string, number>();
  for (const e of registered) {
    leafIndexOf.set(BigNumber.from(e.args!.chainId).toString(), e.args!.leafIndex.toNumber());
  }
  const chainRootOf = new Map<string, string>();
  const sorted = submitted.slice().sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
  for (const e of sorted) {
    chainRootOf.set(BigNumber.from(e.args!.chainId).toString(), e.args!.chainImtRoot as string);
  }

  const leaves: string[] = new Array(leafIndexOf.size).fill(IMT_EMPTY_LEAF);
  for (const [chainId, idx] of leafIndexOf.entries()) {
    const root = chainRootOf.get(chainId);
    if (root) leaves[idx] = globalLeaf(chainId, root);
  }
  return { leaves, leafIndexOf, chainRootOf, root: buildTree(leaves).root };
}

// ── Proof builders ────────────────────────────────────────────────────────────────────────

/** Full inclusion proof for `value` in `chainId`'s IMT, anchored to the global root at `l1Block`. */
export async function buildInclusionProof(params: {
  l2Tree: Contract;
  registry: Contract;
  chainId: BigNumber | number | string;
  value: string;
  l1Block: number;
  l2BlockTag?: number;
}): Promise<InclusionProof> {
  const { l2Tree, registry, chainId, value, l1Block, l2BlockTag } = params;
  const imt = await reconstructChainImt(l2Tree, l2BlockTag);
  const v = BigNumber.from(value);
  const idx = imt.leaves.findIndex((l) => BigNumber.from(l.value).eq(v));
  if (idx < 0) throw new Error(`value ${value} not found in chain ${chainId.toString()} IMT`);

  const snapshot = await reconstructGlobal(registry, l1Block);
  const cid = BigNumber.from(chainId).toString();
  const globalLeafIndex = snapshot.leafIndexOf.get(cid);
  if (globalLeafIndex === undefined) throw new Error(`chain ${cid} not registered at L1 block ${l1Block}`);
  const globalTree = buildTree(snapshot.leaves);

  return {
    chainId: cid,
    chainImtRoot: imt.root,
    leaf: imt.leaves[idx],
    imtLeafIndex: idx,
    imtProof: merklePath(imt.tree, idx),
    globalLeafIndex,
    globalProof: merklePath(globalTree, globalLeafIndex),
    l1BlockNumber: l1Block,
  };
}

/** O(log n) non-inclusion proof that `value` is absent from `chainId`'s IMT across the deadline. */
export async function buildNonInclusionProof(params: {
  l2Tree: Contract;
  registry: Contract;
  chainId: BigNumber | number | string;
  value: string;
  l1BlockBefore: number;
  l1BlockAfter: number;
  l2BlockTag?: number;
}): Promise<NonInclusionProof> {
  const { l2Tree, registry, chainId, value, l1BlockBefore, l1BlockAfter, l2BlockTag } = params;
  const imt = await reconstructChainImt(l2Tree, l2BlockTag);
  const lowIndex = findLowNullifierIndex(imt.leaves, value); // throws if value present

  const cid = BigNumber.from(chainId).toString();
  const before = await reconstructGlobal(registry, l1BlockBefore);
  const after = await reconstructGlobal(registry, l1BlockAfter);
  const globalLeafIndex = before.leafIndexOf.get(cid);
  if (globalLeafIndex === undefined) throw new Error(`chain ${cid} not registered at L1 block ${l1BlockBefore}`);

  return {
    chainId: cid,
    chainImtRoot: imt.root,
    lowLeaf: imt.leaves[lowIndex],
    lowLeafIndex: lowIndex,
    imtProof: merklePath(imt.tree, lowIndex),
    globalLeafIndex,
    l1BlockNumberBeforeDeadline: l1BlockBefore,
    globalProofG1: merklePath(buildTree(before.leaves), globalLeafIndex),
    l1BlockNumberAfterDeadline: l1BlockAfter,
    globalProofG2: merklePath(buildTree(after.leaves), globalLeafIndex),
  };
}
