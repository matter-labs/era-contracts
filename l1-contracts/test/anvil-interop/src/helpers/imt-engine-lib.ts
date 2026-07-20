/**
 * Off-chain counterpart of the atomic-interop proof system (InteropCenter / InteropHandler /
 * AtomicFlowManager). It ports the on-chain IndexedMerkleTree exactly, so the harness can:
 *   - reproduce the per-chain {L2InteropCommitmentTree} root and Merkle paths from the live leaf set
 *     (checked against `tree.root()` / `tree.merklePath(i)` over RPC),
 *   - compute the low-nullifier index needed to insert a value (forwarded to `AtomicFlowManager.append`),
 *   - build the inclusion / non-inclusion {ImtProof} structs the {AtomicFlowManager} verifies.
 *
 * Id derivations:
 *   - `bundleHash = keccak256(abi.encode(sourceChainId, abi.encode(InteropBundle)))`. The atomic send
 *     params (flowId, deadline, lowNullifierIndex) travel via the `atomicBundle` attribute, not the
 *     InteropBundle, so `bundleHash` does not depend on `flowId`.
 *   - `flowId = keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline, settlementLayerChainId))`,
 *     bundle hashes strictly ascending with source chain ids positionally aligned. Since `bundleHash` is
 *     independent of `flowId`, `flowId` is computable off-chain before the send.
 *   - `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))`.
 *
 * Tree specifics (match IndexedMerkleTree.sol + FullMerkle.sol, the dynamic-height tree):
 *   - the FullMerkle tree starts at height 0 and grows by one whenever a leaf lands at index (1 << height);
 *     root() is the top-level node and merklePath(i) has length == the current height,
 *   - leaf is `IMTLeaf { uint256 value; uint256 nextIndex; uint256 nextValue }` (note the field order),
 *   - leaf hash = keccak256(abi.encode(value, nextIndex, nextValue)),
 *   - node hashing via efficientHash(a,b) = keccak256(a ++ b); zeros[0] = keccak256("zkSync:IndexedMerkleTree:emptyLeaf")
 *     (the domain-separated empty-leaf padding, NOT hashLeaf({0,0,0}) — see IMT_EMPTY_LEAF_HASH in Config.sol),
 *     zeros[i+1] = efficientHash(zeros[i], zeros[i]), built lazily as the tree grows,
 *   - the tree seeds the {0,0,0} head at index 0, then appends each inserted leaf and repoints its
 *     low-nullifier, splicing the sorted linked list (forward search bounded by MAX_LOW_INDEX_SEARCH_ATTEMPTS).
 *
 * A chain's IMT root is authenticated as a **chain-batch-root leaf** (leaf 2 = batch begin, leaf 3 =
 * batch end; see ChainBatchRootTree.sol) via {L2_MESSAGE_VERIFICATION}.proveL2LeafInclusionShared. On
 * the harness that address hosts {MockL2MessageVerification}, which always returns true, so the root
 * check is out of harness scope. {AtomicInteropProof} re-parses the same `settlementProof` bytes with
 * the real {MessageHashing} accessors and REQUIRES the leaf-to-batch-root section of the proof to be
 * exactly CHAIN_BATCH_ROOT_TREE_DEPTH (3) hops, so the harness builds format-valid multi-hop proof
 * bytes carrying a chosen `l1Timestamp` and batch-leaf path ({buildSlProofBytes}). The parts actually
 * exercised are the IMT membership / low-nullifier layer and the timeout-protocol clock checks; the
 * protocol itself (finality/timeout conditions, branches, boundaries) is described ONCE in the
 * AtomicInteropProof.sol library header — the settlement interop root timestamps it reads come from
 * the REAL `L2InteropRootStorage.interopRoots[slChainId][slBlock]` tuples, which the harness adds via
 * bootloader impersonation.
 */

import type { providers, Wallet } from "ethers";
import { BigNumber, Contract, utils } from "ethers";
import { getAbi } from "../core/contracts";

/**
 * Max forward hops of the low-leaf search when the caller-supplied low-nullifier index is stale —
 * mirrors MAX_LOW_INDEX_SEARCH_ATTEMPTS in contracts/common/Config.sol.
 */
export const MAX_LOW_INDEX_SEARCH_ATTEMPTS = 5;

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
 * Mirror of `ImtProof` in IAtomicInterop.sol, used for both inclusion and non-inclusion. The IMT part
 * (chainImtRoot/leaf/imtLeafIndex/imtProof) is built from the engine; the settlement part
 * (batchNumber/settlementProof) authenticates `chainImtRoot` as a chain-batch-root leaf (2 = batch
 * begin for absence, 3 = batch end for inclusion — the mask is hardcoded on-chain per verify path)
 * and, via {MessageHashing._getProofData}, carries the `l1Timestamp` used for the deadline check.
 * For inclusion `leaf` is the value's own leaf; for non-inclusion it is the low-nullifier
 * (predecessor) leaf.
 */
export interface ImtProof {
  sourceChainId: string;
  batchNumber: string;
  chainImtRoot: string;
  /** Timeout-branch selector: true authenticates against the batch-BEGIN root (leaf 2), false the
   * batch-END root (leaf 3). Validated on-chain against the authenticated batch `l1Timestamp`
   * (begin => late batch, end => in-time last batch); ignored by the finality path. */
  provesAgainstBeginRoot: boolean;
  settlementProof: string[];
  leaf: IMTLeaf;
  imtLeafIndex: number;
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
 * flowId = keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline, settlementLayerChainId)),
 * matching {AtomicFlowManager}'s preimage. `bundleHashes` must be strictly ascending, `chainIds` are
 * positionally aligned, and `settlementLayerChainId` binds all legs to a single settlement layer.
 */
export function computeFlowId(
  bundleHashes: string[],
  chainIds: (BigNumber | number | string)[],
  deadline: number,
  settlementLayerChainId: BigNumber | number | string = DEFAULT_SL_CHAIN_ID
): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(
      ["bytes32[]", "uint256[]", "uint64", "uint256"],
      [bundleHashes, chainIds.map((c) => BigNumber.from(c)), deadline, BigNumber.from(settlementLayerChainId)]
    )
  );
}

// ── Dynamic-height FullMerkle port (leaf hashing / root / path) ───────────────────

/** efficientHash(a, b) = keccak256(a ++ b) over the two 32-byte siblings — matches Merkle.sol. */
function efficientHash(left: string, right: string): string {
  return utils.keccak256(utils.concat([left, right]));
}

/**
 * Dynamic-height Indexed Merkle Tree, a byte-for-byte off-chain port of
 * {FullMerkle}+{IndexedMerkleTree}. It replays the EXACT on-chain build sequence
 * (`setup` -> `pushNewLeaf` per leaf, with `updateLeaf` mutating the populated path) so that
 * `root()` and `merklePath(i)` equal the on-chain `tree.root()` / `tree.merklePath(i)`.
 *
 * The constructor takes the index-ordered leaf set (index 0 = the {0,0,0} sentinel head, exactly
 * what `setup` seeds). It does NOT re-derive the sorted linked list; the leaves passed in are the
 * live on-chain leaf preimages (or the result of local `insert` calls), so their `nextIndex`/
 * `nextValue` are already spliced. Only the FullMerkle node bookkeeping is replayed here.
 *
 * FullMerkle storage mirror:
 *   - `height`             : current tree height (0 for a single-leaf tree),
 *   - `nodes[level][index]`: written node hashes (dynamic arrays, matching `_nodes`),
 *   - `zeros[level]`       : zero-subtree hash at `level` (matching `_zeros`),
 *   - `leafNumber`         : number of leaves pushed so far.
 */
export class IndexedMerkleTree {
  /** Index-ordered leaves (leaf 0 = head). */
  readonly leaves: IMTLeaf[];
  /** _nodes[level][index] — populated node hashes; higher indices are implicitly zeros[level]. */
  private nodes: string[][];
  /** _zeros[level] — zero-subtree hash per level, grown lazily with the tree. */
  private zeros: string[];
  /** _height — current top level. */
  private height: number;
  /** _leafNumber — leaves pushed so far. */
  private leafNumber: number;

  constructor(leaves: IMTLeaf[]) {
    this.leaves = leaves;
    this.nodes = [];
    this.zeros = [];
    this.height = 0;
    this.leafNumber = 0;

    if (leaves.length === 0) {
      throw new Error("IndexedMerkleTree requires at least the sentinel leaf at index 0");
    }

    // Mirror IndexedMerkleTree.setup: seed the domain-separated padding value (NOT hashLeaf({0,0,0}), so
    // padded indices can't forge a {0,0,0} low leaf — see IMT_EMPTY_LEAF_HASH in Config.sol; must match
    // on-chain), then push the real {0,0,0} sentinel at index 0.
    const emptyLeafPadding = utils.keccak256(utils.toUtf8Bytes("zkSync:IndexedMerkleTree:emptyLeaf"));
    const sentinelLeafHash = indexedLeafHash({ value: "0", nextIndex: "0", nextValue: "0" });
    this.setup(emptyLeafPadding);
    this.pushNewLeaf(sentinelLeafHash);

    // The `setup`/`pushNewLeaf` above seed index 0 from a pristine {0,0,0} sentinel. In a live tree the
    // head leaf has been repointed (its `nextIndex`/`nextValue` splice to the smallest inserted value),
    // so re-write index 0 with its actual on-chain preimage before pushing leaves 1..n-1 in order.
    this.updateLeaf(0, indexedLeafHash(leaves[0]));
    for (let i = 1; i < leaves.length; i++) {
      this.pushNewLeaf(indexedLeafHash(leaves[i]));
    }
  }

  // ── FullMerkle port ───────────────────────────────────────────────────────────────────────

  /** FullMerkle.setup: push the zero value into zeros[0] and seed nodes[0] = [zero]. */
  private setup(zero: string): void {
    this.zeros.push(zero);
    this.nodes.push([zero]);
  }

  /** FullMerkle.pushNewLeaf: append a leaf, growing the tree height when index == 1<<height. */
  private pushNewLeaf(leaf: string): string {
    const index = this.leafNumber;
    this.leafNumber += 1;

    if (index === 1 << this.height) {
      const newHeight = this.height + 1;
      this.height = newHeight;
      const topZero = this.zeros[newHeight - 1];
      const newZero = efficientHash(topZero, topZero);
      this.zeros.push(newZero);
      this.nodes.push([newZero]);
    }
    if (index !== 0) {
      let oldMaxNodeNumber = index - 1;
      let maxNodeNumber = index;
      for (let i = 0; i < this.height; i++) {
        if (oldMaxNodeNumber === maxNodeNumber) {
          break;
        }
        this.nodes[i].push(this.zeros[i]);
        maxNodeNumber = Math.floor(maxNodeNumber / 2);
        oldMaxNodeNumber = Math.floor(oldMaxNodeNumber / 2);
      }
    }
    return this.updateLeaf(index, leaf);
  }

  /** FullMerkle.updateLeaf: set leaf hash at `index` and rehash the populated path to the root. */
  private updateLeaf(startIndex: number, itemHash: string): string {
    let maxNodeNumber = this.leafNumber - 1;
    if (startIndex > maxNodeNumber) {
      throw new Error(`MerkleWrongIndex(${startIndex}, ${maxNodeNumber})`);
    }
    let index = startIndex;
    this.nodes[0][index] = itemHash;
    let currentHash = itemHash;
    for (let i = 0; i < this.height; i++) {
      if (index % 2 === 0) {
        currentHash = efficientHash(currentHash, maxNodeNumber === index ? this.zeros[i] : this.nodes[i][index + 1]);
      } else {
        currentHash = efficientHash(this.nodes[i][index - 1], currentHash);
      }
      index = Math.floor(index / 2);
      maxNodeNumber = Math.floor(maxNodeNumber / 2);
      this.nodes[i + 1][index] = currentHash;
    }
    return currentHash;
  }

  /** FullMerkle.root: the node at the current top level. */
  root(): string {
    return this.nodes[this.height][0];
  }

  /** FullMerkle.merklePath: dynamic-length path (length == current height) for the leaf at `index`. */
  merklePath(startIndex: number): string[] {
    if (this.leafNumber === 0) {
      throw new Error("MerkleNothingToProve");
    }
    let maxNodeNumber = this.leafNumber - 1;
    if (startIndex > maxNodeNumber) {
      throw new Error(`MerkleWrongIndex(${startIndex}, ${maxNodeNumber})`);
    }
    let index = startIndex;
    const proof: string[] = new Array(this.height);
    for (let i = 0; i < this.height; i++) {
      if (index % 2 === 0) {
        proof[i] = maxNodeNumber === index ? this.zeros[i] : this.nodes[i][index + 1];
      } else {
        proof[i] = this.nodes[i][index - 1];
      }
      index = Math.floor(index / 2);
      maxNodeNumber = Math.floor(maxNodeNumber / 2);
    }
    return proof;
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

/** Default settlement-layer chain id encoded into proof bytes and bound into flow ids. Must equal
 * the L1 chain id the AtomicFlowManager was initialized with (`initL2`): in this release interop
 * legs settle on L1 only and the manager rejects flows declaring any other settlement layer. The
 * harness L1 is the default anvil chain (31337). */
export const DEFAULT_SL_CHAIN_ID = 31337;

/** Depth of the chain batch root tree — mirrors ChainBatchRootTree.TREE_DEPTH; the on-chain
 * verifier requires the leaf-to-batch-root proof section to be exactly this long. */
export const CHAIN_BATCH_ROOT_TREE_DEPTH = 3;

/**
 * Builds the minimal format-valid multi-hop leaf inclusion proof bytes that
 * {MessageHashing._getProofData} parses into a chosen `l1Timestamp` and settlement-layer
 * chain id (with `finalProofNode == false`). `slBlock` identifies the settlement interop root tuple
 * that the timeout path reads from `interopRoots[slChainId][slBlock]`.
 *
 * Byte layout (logLeafProofLen=3 — the chain-batch-root top-tree path {AtomicInteropProof} enforces):
 *   [0]      metadata header = version(0x01) | logLeafProofLen(3) | batchLeafProofLen(n) |
 *            finalProofNode(0); the low 28 bytes MUST be zero (new versioned format).
 *   [1..3]   the 3 top-tree siblings hashing the IMT-root leaf up to the chain batch root. Placeholders
 *            on the harness ({MockL2MessageVerification} accepts any leaf/root); in production these are
 *            the real siblings (other IMT root, node(logsRoot, multichainRoot), reserved-subtree node).
 *   [4]      l1Timestamp = the settlement-layer timestamp bound into the batch leaf (read right after
 *            the leaf proof). Format-only on the harness, so a chosen value.
 *   [5]      batchLeafProofMask (`batchLeafMask`).
 *   [6..6+n) the batch-leaf path siblings (`batchLeafSiblings`; the chain's batch tree inside the SL
 *            shared root). Empty by default — a single-leaf (genesis-only) chain tree has a
 *            zero-length path — which also makes the timeout protocol's "last batch in root" check
 *            trivially pass. Supply non-empty siblings to exercise that check.
 *   [last-1] settlementLayerPackedBatchInfo = (slBlock << 128) | mask(0).
 *   [last]   settlementLayerChainId.
 * The leaf-proof mask is supplied on-chain by the verify path (2 = batch-begin leaf, 3 = batch-end
 * leaf, selected by the verify function / timeout branch).
 */
export function buildSlProofBytes(
  slBlock: number,
  slChainId: number = DEFAULT_SL_CHAIN_ID,
  l1Timestamp: BigNumber | number | string = 0,
  batchLeafSiblings: string[] = [],
  batchLeafMask: BigNumber | number | string = 0
): string[] {
  const metadata = utils.hexZeroPad(
    BigNumber.from(0x01)
      .shl(248)
      .or(BigNumber.from(CHAIN_BATCH_ROOT_TREE_DEPTH).shl(240))
      .or(BigNumber.from(batchLeafSiblings.length).shl(232))
      .toHexString(),
    32
  );
  const topTreeSiblings = new Array(CHAIN_BATCH_ROOT_TREE_DEPTH).fill(utils.hexZeroPad("0x00", 32));
  const l1TimestampWord = utils.hexZeroPad(BigNumber.from(l1Timestamp).toHexString(), 32);
  const batchLeafProofMask = utils.hexZeroPad(BigNumber.from(batchLeafMask).toHexString(), 32);
  const packedBatchInfo = utils.hexZeroPad(BigNumber.from(slBlock).shl(128).toHexString(), 32);
  const settlementLayerChainId = utils.hexZeroPad(BigNumber.from(slChainId).toHexString(), 32);
  return [
    metadata,
    ...topTreeSiblings,
    l1TimestampWord,
    batchLeafProofMask,
    ...batchLeafSiblings.map((s) => utils.hexZeroPad(s, 32)),
    packedBatchInfo,
    settlementLayerChainId,
  ];
}

/**
 * Well-formed settlement proof carrying a chosen `l1Timestamp`, batch number and SL snapshot block.
 * {MockL2MessageVerification} accepts any leaf, but {MessageHashing._getProofData} parses these bytes
 * to derive `t`, the SL chain id and the SL snapshot block, which {AtomicInteropProof} uses for the
 * clock checks (see the AtomicInteropProof.sol library header for the conditions).
 */
function settlementProofForBatch(params: {
  l1Timestamp: BigNumber | number | string;
  batchNumber?: number | string;
  slChainId?: number;
  slBlock?: number;
  batchLeafSiblings?: string[];
  batchLeafMask?: BigNumber | number | string;
}): {
  batchNumber: string;
  settlementProof: string[];
} {
  const {
    l1Timestamp,
    batchNumber = "1",
    slChainId = DEFAULT_SL_CHAIN_ID,
    slBlock = 1,
    batchLeafSiblings = [],
    batchLeafMask = 0,
  } = params;
  return {
    batchNumber: batchNumber.toString(),
    settlementProof: buildSlProofBytes(slBlock, slChainId, l1Timestamp, batchLeafSiblings, batchLeafMask),
  };
}

/**
 * Build an inclusion {ImtProof} for `value` against `chainId`'s live IMT (`leaf` is the value's own leaf),
 * carrying `l1Timestamp` (must satisfy the finality bound — see AtomicInteropProof.sol).
 */
export async function buildInclusionProof(params: {
  l2Tree: Contract;
  chainId: BigNumber | number | string;
  value: string;
  l1Timestamp: BigNumber | number | string;
  slChainId?: number;
  l2BlockTag?: number;
}): Promise<ImtProof> {
  const { l2Tree, chainId, value, l1Timestamp, slChainId, l2BlockTag } = params;
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
    // The finality path always authenticates the end root; the branch selector is ignored.
    provesAgainstBeginRoot: false,
    leaf: imt.leaves[idx],
    imtLeafIndex: idx,
    imtProof: imt.engine.merklePath(idx),
    ...settlementProofForBatch({ l1Timestamp, slChainId }),
  };
}

/**
 * Build the timeout absence {ImtProof}: proves `value` is absent from `chainId`'s live IMT (`leaf` is
 * the low-nullifier / predecessor leaf). The live tree root stands in for the batch-begin (late
 * batch) or batch-end (last in-time batch) IMT root snapshot on the harness; the timeout conditions
 * the proof is checked against are described in the AtomicInteropProof.sol library header, and the
 * settlement interop root it resolves is added via bootloader impersonation (see the spec's
 * `ensureSettlementInteropRoot`).
 */
export async function buildNonInclusionProof(params: {
  l2Tree: Contract;
  chainId: BigNumber | number | string;
  value: string;
  l1Timestamp: BigNumber | number | string;
  /** The declared timeout branch (see {ImtProof.provesAgainstBeginRoot}); an honest prover uses
   * `l1Timestamp > deadline`. */
  provesAgainstBeginRoot: boolean;
  batchNumber?: number | string;
  slChainId?: number;
  slBlock?: number;
  batchLeafSiblings?: string[];
  batchLeafMask?: BigNumber | number | string;
  l2BlockTag?: number;
}): Promise<ImtProof> {
  const {
    l2Tree,
    chainId,
    value,
    l1Timestamp,
    provesAgainstBeginRoot,
    batchNumber = 1,
    slChainId,
    slBlock,
    batchLeafSiblings,
    batchLeafMask,
    l2BlockTag,
  } = params;
  const imt = await reconstructChainImt(l2Tree, l2BlockTag);
  const lowIndex = findLowNullifierIndex(imt.leaves, value); // throws if value present

  const onChainRoot: string = await l2Tree.root(l2BlockTag !== undefined ? { blockTag: l2BlockTag } : {});
  if (imt.root.toLowerCase() !== onChainRoot.toLowerCase()) {
    throw new Error(`off-chain IMT root ${imt.root} != on-chain root ${onChainRoot} for chain ${chainId.toString()}`);
  }

  return {
    sourceChainId: BigNumber.from(chainId).toString(),
    chainImtRoot: imt.root,
    provesAgainstBeginRoot,
    leaf: imt.leaves[lowIndex],
    imtLeafIndex: lowIndex,
    imtProof: imt.engine.merklePath(lowIndex),
    ...settlementProofForBatch({ l1Timestamp, batchNumber, slChainId, slBlock, batchLeafSiblings, batchLeafMask }),
  };
}

// ── Tuple encoders (ordered for ethers contract calls) ────────────────────────────────────

/** IMTLeaf tuple in struct field order (value, nextIndex, nextValue). */
export function leafTuple(l: IMTLeaf): unknown[] {
  return [l.value, l.nextIndex, l.nextValue];
}

/** ImtProof tuple in struct field order (same for inclusion and non-inclusion). */
export function proofTuple(p: ImtProof): unknown[] {
  return [
    p.sourceChainId,
    p.batchNumber,
    p.chainImtRoot,
    p.provesAgainstBeginRoot,
    p.settlementProof,
    leafTuple(p.leaf),
    p.imtLeafIndex,
    p.imtProof,
  ];
}

/**
 * Build the `AtomicFlow` tuple {AtomicFlowManager} consumes (the flow definition). Tuple field order
 * matches the struct: (flowId, deadline, settlementLayerChainId, legBundleHashes, legSourceChainIds).
 * `legBundleHashes` is ascending; `chainIds` is positionally aligned; `settlementLayerChainId` defaults
 * to {DEFAULT_SL_CHAIN_ID}.
 */
export function atomicFlowTuple(params: {
  flowId: string;
  deadline: number;
  settlementLayerChainId?: BigNumber | number | string;
  legBundleHashes: string[];
  chainIds: (BigNumber | number | string)[];
}): unknown[] {
  return [
    params.flowId,
    params.deadline,
    BigNumber.from(params.settlementLayerChainId ?? DEFAULT_SL_CHAIN_ID),
    params.legBundleHashes,
    params.chainIds.map((c) => BigNumber.from(c)),
  ];
}

/**
 * Build the `AtomicFinalityProof` tuple {L2InteropHandler.executeAtomicBundle} consumes: the flow
 * definition ({AtomicFlow}) plus one inclusion proof per leg, in `legBundleHashes` order. Tuple field
 * order matches the struct: (flow, proofs).
 */
export function atomicFinalityProofTuple(params: {
  flowId: string;
  deadline: number;
  settlementLayerChainId?: BigNumber | number | string;
  legBundleHashes: string[];
  chainIds: (BigNumber | number | string)[];
  proofs: ImtProof[];
}): unknown[] {
  return [atomicFlowTuple(params), params.proofs.map(proofTuple)];
}
