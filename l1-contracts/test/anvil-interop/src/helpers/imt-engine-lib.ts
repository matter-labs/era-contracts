/**
 * IMT engine library — the off-chain counterpart of the L1-free atomic-interop proof system
 * (bundle model: InteropCenter / InteropHandler / AtomicFlowManager).
 *
 * It implements **IMT engine B** ({IndexedMerkleTreeLib}) exactly, so the harness can:
 *   - reproduce, byte-for-byte, the per-chain {L2InteropCommitmentTree} root and Merkle paths from
 *     the tree's live leaf set (verified against `tree.root()` / `tree.merklePath(i)` over RPC),
 *   - compute the low-nullifier index needed to insert a value (the `lowNullifierIndex` carried by the
 *     `atomicBundle` attribute, which the InteropCenter forwards to `AtomicFlowManager.append`),
 *   - build the {ImtInclusionProof} / {ImtNonInclusionProof} structs the {AtomicFlowManager} verifies
 *     (packed into the {AtomicFinalityProof} the {InteropHandler.executeAtomicBundle} consumes).
 *
 * The flow ids:
 *   - `bundleHash = keccak256(abi.encode(sourceChainId, abi.encode(InteropBundle)))`, where the
 *     InteropBundle is the one the InteropCenter emits in `InteropBundleSent`. The atomic send params
 *     (flowId, deadline, lowNullifierIndex) travel via the `atomicBundle` ERC-7786 attribute and are
 *     parsed by the InteropCenter into an internal `AtomicSend` struct — they are NOT part of the
 *     InteropBundle, so `bundleHash` does NOT depend on `flowId`.
 *   - `flowId = keccak256(abi.encode(sortedBundleHashes, sortedChainIds, deadline))` (both arrays
 *     strictly ascending). Because `bundleHash` is independent of `flowId`, `flowId` is computable
 *     off-chain BEFORE the send — which breaks the old circular dependency.
 *   - `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
 *
 * Engine B specifics (must match contracts/common/libraries/IndexedMerkleTree.sol):
 *   - fixed depth 32 (`IMT_DEPTH`); 2^32 leaf slots,
 *   - leaf is `IMTLeaf { uint256 value; uint256 nextIndex; uint256 nextValue }` — NOTE the field
 *     order (value, nextIndex, nextValue),
 *   - leaf hash = keccak256(abi.encode(value, nextIndex, nextValue)),
 *   - sparse tree with precomputed zero-subtree hashes: zeros[0] = hashLeaf({0,0,0}),
 *     zeros[i+1] = efficientHash(zeros[i], zeros[i]) where efficientHash(a,b) = keccak256(a ++ b),
 *   - the commitment tree seeds the {0,0,0} head at index 0 (`setup`), then appends each inserted
 *     leaf and repoints its low-nullifier (`insert`).
 *
 * The cross-chain `(root)` message that authenticates a chain's IMT root is verified on-chain via
 * {L2_MESSAGE_VERIFICATION}.proveL2MessageInclusionShared. On the anvil harness that address hosts
 * {MockL2MessageVerification}, which always returns true — so the real root check is out of harness
 * scope. The deadline is a **settlement-layer (SL) block number**: {AtomicInteropProof} re-parses the
 * SAME `messageProof` bytes with the real {MessageHashing._getProofData} (NOT mocked) to derive the SL
 * block, so the harness builds format-valid multi-hop proof bytes carrying a CHOSEN `slBlock`
 * ({buildSlProofBytes}). The IMT membership / low-nullifier layer and the SL-block deadline check are
 * the parts actually exercised. This mirrors the Foundry AtomicFlowManager tests.
 */

import type { providers, Wallet } from "ethers";
import { BigNumber, Contract, utils } from "ethers";
import { getAbi } from "../core/contracts";

/** Fixed depth of the Indexed Merkle Tree — matches IMT_DEPTH in IndexedMerkleTree.sol. */
export const IMT_DEPTH = 32;

/** Domain tag for commit values: bytes4(keccak256("AtomicInterop.commit.v1")). */
export const ATOMIC_COMMIT_LEAF_TAG: string = utils
  .keccak256(utils.toUtf8Bytes("AtomicInterop.commit.v1"))
  .slice(0, 10);

/** Indexed-tree leaf, fields as uint256 decimal strings, in the on-chain field order. */
export interface IMTLeaf {
  value: string;
  nextIndex: string;
  nextValue: string;
}

/**
 * Mirror of `ImtInclusionProof` in IAtomicInterop.sol. The IMT part (chainImtRoot/leaf/imtLeafIndex/
 * imtProof) is built from the engine; the message-inclusion part (batchNumber/messageIndex/
 * messageProof/messageTxNumberInBatch) authenticates the `(root)` L2->L1 message AND, via the real
 * {MessageHashing._getProofData} parse, carries the settlement-layer block number used for the
 * deadline check (`messageProof` is a format-valid multi-hop proof — see {buildSlProofBytes}).
 */
export interface ImtInclusionProof {
  sourceChainId: string;
  batchNumber: string;
  chainImtRoot: string;
  messageTxNumberInBatch: number;
  messageIndex: string;
  messageProof: string[];
  leaf: IMTLeaf;
  imtLeafIndex: number;
  imtProof: string[];
}

/** Mirror of `ImtNonInclusionProof` in IAtomicInterop.sol. */
export interface ImtNonInclusionProof {
  sourceChainId: string;
  batchNumber: string;
  chainImtRoot: string;
  messageTxNumberInBatch: number;
  messageIndex: string;
  messageProof: string[];
  lowLeaf: IMTLeaf;
  lowLeafIndex: number;
  imtProof: string[];
}

// ── Leaf / id derivations (must match AtomicInteropProof / AtomicFlowManager) ──────────────

/** The value inserted into a chain's IMT for a leg, as a 0x bytes32 (also a valid uint256). */
export function commitValue(flowId: string, bundleHash: string): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(["bytes4", "bytes32", "bytes32"], [ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash])
  );
}

/** Leaf hash in the engine's canonical layout: keccak256(abi.encode(value, nextIndex, nextValue)). */
export function indexedLeafHash(leaf: IMTLeaf): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(["uint256", "uint256", "uint256"], [leaf.value, leaf.nextIndex, leaf.nextValue])
  );
}

/**
 * flowId = keccak256(abi.encode(sortedBundleHashes, sortedChainIds, deadline)) — must match
 * {AtomicFlowManager._checkFlowId}. Both arrays must already be strictly ascending.
 */
export function computeFlowId(
  bundleHashes: string[],
  chainIds: (BigNumber | number | string)[],
  deadline: number
): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(
      ["bytes32[]", "uint256[]", "uint64"],
      [bundleHashes, chainIds.map((c) => BigNumber.from(c)), deadline]
    )
  );
}

// ── Engine B: zeros / leaf hashing / root / path ──────────────────────────────────────────

/** efficientHash(a, b) = keccak256(a ++ b) over the two 32-byte siblings — matches Merkle.sol. */
function efficientHash(left: string, right: string): string {
  return utils.keccak256(utils.concat([left, right]));
}

/**
 * Precomputed zero-subtree hashes, length IMT_DEPTH + 1.
 *   zeros[0] = hashLeaf({0,0,0}); zeros[i+1] = efficientHash(zeros[i], zeros[i]).
 */
export function computeZeros(): string[] {
  const zeros: string[] = new Array(IMT_DEPTH + 1);
  zeros[0] = indexedLeafHash({ value: "0", nextIndex: "0", nextValue: "0" });
  for (let i = 0; i < IMT_DEPTH; i++) {
    zeros[i + 1] = efficientHash(zeros[i], zeros[i]);
  }
  return zeros;
}

const ZEROS = computeZeros();

/**
 * Sparse fixed-depth Indexed Merkle Tree reconstructed from the index-ordered leaf set
 * `leaves[0..leafCount-1]` (index 0 is the {0,0,0} head). Mirrors the on-chain `IMT` storage:
 * `nodes[level][index]` holds written nodes, and unwritten siblings default to `zeros[level]`.
 */
export class IndexedMerkleTree {
  /** Index-ordered leaves (leaf 0 = head). */
  readonly leaves: IMTLeaf[];
  /** nodes[level] : Map<index, hash> — only the populated path nodes are materialized. */
  private readonly nodes: Array<Map<number, string>>;

  constructor(leaves: IMTLeaf[]) {
    this.leaves = leaves;
    this.nodes = Array.from({ length: IMT_DEPTH + 1 }, () => new Map<number, string>());
    // Level 0: write each leaf hash at its index.
    for (let i = 0; i < leaves.length; i++) {
      this.nodes[0].set(i, indexedLeafHash(leaves[i]));
    }
    // Build every higher level from the parents of populated children (and their zero-filled
    // siblings), so a node is materialized iff at least one descendant leaf is populated. This
    // matches the on-chain `_updatePath` write set and therefore yields identical roots / paths.
    for (let level = 0; level < IMT_DEPTH; level++) {
      const parents = new Set<number>();
      for (const childIndex of this.nodes[level].keys()) {
        parents.add(childIndex >> 1);
      }
      for (const parentIndex of parents) {
        const leftIndex = parentIndex * 2;
        const left = this.nodeAt(level, leftIndex);
        const right = this.nodeAt(level, leftIndex + 1);
        this.nodes[level + 1].set(parentIndex, efficientHash(left, right));
      }
    }
  }

  /** Read a node, falling back to the level's zero hash when unwritten. */
  private nodeAt(level: number, index: number): string {
    return this.nodes[level].get(index) ?? ZEROS[level];
  }

  /** The current IMT root (level IMT_DEPTH, index 0). */
  root(): string {
    return this.nodeAt(IMT_DEPTH, 0);
  }

  /** Fixed-depth Merkle path (32 siblings, leaf level up) for the leaf at `index`. */
  merklePath(index: number): string[] {
    const path: string[] = new Array(IMT_DEPTH);
    let idx = index;
    for (let level = 0; level < IMT_DEPTH; level++) {
      const siblingIdx = idx % 2 === 0 ? idx + 1 : idx - 1;
      path[level] = this.nodeAt(level, siblingIdx);
      idx = Math.floor(idx / 2);
    }
    return path;
  }
}

/** Verify a leaf's Merkle path resolves to `root` — mirrors Merkle.calculateRootMemory. */
export function calculateRoot(path: string[], index: number, leafHash: string): string {
  let current = leafHash;
  let idx = index;
  for (let level = 0; level < path.length; level++) {
    current = idx % 2 === 0 ? efficientHash(current, path[level]) : efficientHash(path[level], current);
    idx = Math.floor(idx / 2);
  }
  return current;
}

// ── Contract handle ────────────────────────────────────────────────────────────────────────

export function commitmentTree(address: string, provider: providers.Provider | Wallet): Contract {
  return new Contract(address, getAbi("L2InteropCommitmentTree"), provider);
}

// ── Chain indexed-tree reconstruction (over RPC) ─────────────────────────────────────────

/**
 * Reconstructs a chain's indexed IMT by reading its live leaf set (`leafCount` + `leafAt`). The
 * engine then reproduces the root / paths, which a caller can assert against `tree.root()` /
 * `tree.merklePath(i)` to confirm the off-chain engine matches the on-chain one.
 */
export async function reconstructChainImt(
  tree: Contract,
  blockTag?: number
): Promise<{ leaves: IMTLeaf[]; engine: IndexedMerkleTree; root: string }> {
  const overrides = blockTag !== undefined ? { blockTag } : {};
  const count: number = (await tree.leafCount(overrides)).toNumber();
  const leaves: IMTLeaf[] = [];
  for (let i = 0; i < count; i++) {
    const l = await tree.leafAt(i, overrides);
    leaves.push({ value: l.value.toString(), nextIndex: l.nextIndex.toString(), nextValue: l.nextValue.toString() });
  }
  const engine = new IndexedMerkleTree(leaves);
  return { leaves, engine, root: engine.root() };
}

/** Index of the low-nullifier leaf for `value`: `L.value < value` and (`L.nextValue == 0` or `value < L.nextValue`). */
export function findLowNullifierIndex(leaves: IMTLeaf[], value: string): number {
  const v = BigNumber.from(value);
  for (let i = 0; i < leaves.length; i++) {
    const lv = BigNumber.from(leaves[i].value);
    const nv = BigNumber.from(leaves[i].nextValue);
    if (lv.lt(v) && (nv.isZero() || v.lt(nv))) return i;
  }
  throw new Error(`no low nullifier for value ${value} (already present or empty tree)`);
}

/** Index of the leaf holding `value`. Returns -1 if absent. */
export function findValueIndex(leaves: IMTLeaf[], value: string): number {
  const v = BigNumber.from(value);
  return leaves.findIndex((l) => BigNumber.from(l.value).eq(v));
}

/** Convenience: low-nullifier index for inserting `value` into the current tree. */
export async function lowNullifierIndexFor(tree: Contract, value: string, blockTag?: number): Promise<number> {
  const imt = await reconstructChainImt(tree, blockTag);
  return findLowNullifierIndex(imt.leaves, value);
}

// ── Proof builders ────────────────────────────────────────────────────────────────────────

/** Default settlement-layer chain id encoded into proof bytes (single-SL assumption). Arbitrary on
 * the harness, since {MockL2MessageVerification} accepts any message; only the SL block is consumed. */
export const DEFAULT_SL_CHAIN_ID = 506;

/**
 * Builds the minimal **format-valid multi-hop** L2-message inclusion proof bytes that the real
 * {MessageHashing._getProofData} parses to a chosen settlement-layer block number `slBlock` (with
 * `finalProofNode == false`). Mirrors `AtomicInteropTestUtils.slProofBytes` in the Foundry suite.
 *
 * Byte layout (logLeafProofLen=0, batchLeafProofLen=0 -> no path nodes, so the mask words are 0):
 *   [0] metadata header = version(0x01) << 248 | logLeafProofLen(0) | batchLeafProofLen(0) |
 *       finalProofNode(0); the low 28 bytes MUST be zero (new versioned format).
 *   [1] batchLeafProofMask = 0.
 *   [2] settlementLayerPackedBatchInfo = (slBlock << 128) | mask(0).
 *   [3] settlementLayerChainId.
 * `messageIndex` (the leaf-proof mask) must be 0, since logLeafProofLen==0 requires index < 1.
 */
export function buildSlProofBytes(slBlock: number, slChainId: number = DEFAULT_SL_CHAIN_ID): string[] {
  const metadata = utils.hexZeroPad(BigNumber.from(0x01).shl(248).toHexString(), 32);
  const batchLeafProofMask = utils.hexZeroPad("0x00", 32);
  const packedBatchInfo = utils.hexZeroPad(BigNumber.from(slBlock).shl(128).toHexString(), 32);
  const settlementLayerChainId = utils.hexZeroPad(BigNumber.from(slChainId).toHexString(), 32);
  return [metadata, batchLeafProofMask, packedBatchInfo, settlementLayerChainId];
}

/**
 * Well-formed message-inclusion proof carrying a chosen settlement-layer block number `slBlock`. On the
 * anvil harness {MockL2MessageVerification} accepts any message (the real root check is out of scope),
 * but {MessageHashing._getProofData} really parses these bytes to derive `slBlock` for the deadline check.
 */
function messageProofForSlBlock(slBlock: number): {
  batchNumber: string;
  messageIndex: string;
  messageTxNumberInBatch: number;
  messageProof: string[];
} {
  return { batchNumber: "1", messageIndex: "0", messageTxNumberInBatch: 0, messageProof: buildSlProofBytes(slBlock) };
}

/**
 * Build an {ImtInclusionProof} for `value` against `chainId`'s live IMT, carrying a proof whose
 * settlement-layer block number is `slBlock` (must be <= the flow deadline for `requireFlowFinalized`
 * to accept).
 */
export async function buildInclusionProof(params: {
  l2Tree: Contract;
  chainId: BigNumber | number | string;
  value: string;
  slBlock: number;
  l2BlockTag?: number;
}): Promise<ImtInclusionProof> {
  const { l2Tree, chainId, value, slBlock, l2BlockTag } = params;
  const imt = await reconstructChainImt(l2Tree, l2BlockTag);
  const idx = findValueIndex(imt.leaves, value);
  if (idx < 0) throw new Error(`value ${value} not found in chain ${chainId.toString()} IMT`);

  // Sanity: our reconstructed root must equal the on-chain root, else the proof would not verify.
  const onChainRoot: string = await l2Tree.root(l2BlockTag !== undefined ? { blockTag: l2BlockTag } : {});
  if (imt.root.toLowerCase() !== onChainRoot.toLowerCase()) {
    throw new Error(`off-chain IMT root ${imt.root} != on-chain root ${onChainRoot} for chain ${chainId.toString()}`);
  }

  return {
    sourceChainId: BigNumber.from(chainId).toString(),
    chainImtRoot: imt.root,
    leaf: imt.leaves[idx],
    imtLeafIndex: idx,
    imtProof: imt.engine.merklePath(idx),
    ...messageProofForSlBlock(slBlock),
  };
}

/**
 * Build an {ImtNonInclusionProof} proving `value` is absent from `chainId`'s live IMT, carrying a proof
 * whose settlement-layer block number is `slBlock` (must be > the flow deadline for `authorizeRefund`
 * to accept). O(log n) via the low-nullifier bracket.
 */
export async function buildNonInclusionProof(params: {
  l2Tree: Contract;
  chainId: BigNumber | number | string;
  value: string;
  slBlock: number;
  l2BlockTag?: number;
}): Promise<ImtNonInclusionProof> {
  const { l2Tree, chainId, value, slBlock, l2BlockTag } = params;
  const imt = await reconstructChainImt(l2Tree, l2BlockTag);
  const lowIndex = findLowNullifierIndex(imt.leaves, value); // throws if value present

  const onChainRoot: string = await l2Tree.root(l2BlockTag !== undefined ? { blockTag: l2BlockTag } : {});
  if (imt.root.toLowerCase() !== onChainRoot.toLowerCase()) {
    throw new Error(`off-chain IMT root ${imt.root} != on-chain root ${onChainRoot} for chain ${chainId.toString()}`);
  }

  return {
    sourceChainId: BigNumber.from(chainId).toString(),
    chainImtRoot: imt.root,
    lowLeaf: imt.leaves[lowIndex],
    lowLeafIndex: lowIndex,
    imtProof: imt.engine.merklePath(lowIndex),
    ...messageProofForSlBlock(slBlock),
  };
}

// ── Tuple encoders (ordered for ethers contract calls) ────────────────────────────────────

/** IMTLeaf tuple in struct field order (value, nextIndex, nextValue). */
export function leafTuple(l: IMTLeaf): unknown[] {
  return [l.value, l.nextIndex, l.nextValue];
}

/** ImtInclusionProof tuple in struct field order. */
export function inclusionProofTuple(p: ImtInclusionProof): unknown[] {
  return [
    p.sourceChainId,
    p.batchNumber,
    p.chainImtRoot,
    p.messageTxNumberInBatch,
    p.messageIndex,
    p.messageProof,
    leafTuple(p.leaf),
    p.imtLeafIndex,
    p.imtProof,
  ];
}

/** ImtNonInclusionProof tuple in struct field order. */
export function nonInclusionProofTuple(p: ImtNonInclusionProof): unknown[] {
  return [
    p.sourceChainId,
    p.batchNumber,
    p.chainImtRoot,
    p.messageTxNumberInBatch,
    p.messageIndex,
    p.messageProof,
    leafTuple(p.lowLeaf),
    p.lowLeafIndex,
    p.imtProof,
  ];
}

/**
 * Build the `AtomicFinalityProof` tuple {InteropHandler.executeAtomicBundle} consumes: the flow
 * definition (flowId, deadline, ascending legBundleHashes + chainIds) plus one inclusion proof per
 * leg, in `legBundleHashes` order. Tuple field order:
 *   (flowId, deadline, legBundleHashes, chainIds, proofs).
 */
export function atomicFinalityProofTuple(params: {
  flowId: string;
  deadline: number;
  legBundleHashes: string[];
  chainIds: (BigNumber | number | string)[];
  proofs: ImtInclusionProof[];
}): unknown[] {
  return [
    params.flowId,
    params.deadline,
    params.legBundleHashes,
    params.chainIds.map((c) => BigNumber.from(c)),
    params.proofs.map(inclusionProofTuple),
  ];
}
