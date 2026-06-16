/**
 * IMT engine library — the off-chain counterpart of the L1-free atomic-interop proof system.
 *
 * It implements **IMT engine B** ({IndexedMerkleTreeLib}) exactly, so the harness can:
 *   - reproduce, byte-for-byte, the per-chain {L2InteropCommitmentTree} root and Merkle paths from
 *     the tree's live leaf set (verified against `tree.root()` / `tree.merklePath(i)` over RPC),
 *   - compute the low-nullifier index needed to `commitSend` (insert) a value,
 *   - build the {ImtInclusionProof} / {ImtNonInclusionProof} structs {AtomicFlowEscrow} verifies.
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
 * The cross-chain `(root, timestamp)` message that authenticates a chain's IMT root is verified
 * on-chain via {L2_MESSAGE_VERIFICATION}.proveL2MessageInclusionShared. On the anvil harness that
 * address hosts {MockL2MessageVerification}, which always returns true — so the message-proof fields
 * of a proof are well-formed placeholders (the IMT membership / low-nullifier layer and the
 * `rootTimestamp` deadline check are the parts actually exercised). This mirrors the Foundry
 * AtomicFlowEscrow tests, which mock the same call and build proofs from real tree state.
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

export interface SendSpec {
  destChainId: BigNumber | number | string;
  recipient: string;
  originChainId: BigNumber | number | string;
  originToken: string;
  amount: BigNumber | number | string;
  erc20Data: string;
  depositor: string;
}

/** Indexed-tree leaf, fields as uint256 decimal strings, in the on-chain field order. */
export interface IMTLeaf {
  value: string;
  nextIndex: string;
  nextValue: string;
}

/**
 * Mirror of `ImtInclusionProof` in IAtomicInterop.sol. The IMT part (chainImtRoot/leaf/imtLeafIndex/
 * imtProof) is built from the engine; the message-inclusion part (batchNumber/messageIndex/
 * messageProof/messageTxNumberInBatch) authenticates the `(root, timestamp)` L2->L1 message.
 */
export interface ImtInclusionProof {
  sourceChainId: string;
  batchNumber: string;
  chainImtRoot: string;
  rootTimestamp: string;
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
  rootTimestamp: string;
  messageTxNumberInBatch: number;
  messageIndex: string;
  messageProof: string[];
  lowLeaf: IMTLeaf;
  lowLeafIndex: number;
  imtProof: string[];
}

// ── Leaf / id derivations (must match AtomicInteropProof / AtomicFlowEscrow) ──────────────

/** The value inserted into a chain's IMT for a leg, as a 0x bytes32 (also a valid uint256). */
export function commitValue(flowId: string, specHash: string): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(["bytes4", "bytes32", "bytes32"], [ATOMIC_COMMIT_LEAF_TAG, flowId, specHash])
  );
}

/** Leaf hash in the engine's canonical layout: keccak256(abi.encode(value, nextIndex, nextValue)). */
export function indexedLeafHash(leaf: IMTLeaf): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(["uint256", "uint256", "uint256"], [leaf.value, leaf.nextIndex, leaf.nextValue])
  );
}

/** specHash = keccak256(abi.encode(SendSpec)) — must match AtomicFlowEscrow / the SendSpec layout. */
export function specHashOf(spec: SendSpec): string {
  return utils.keccak256(
    utils.defaultAbiCoder.encode(
      ["tuple(uint256,address,uint256,address,uint256,bytes,address)"],
      [
        [
          BigNumber.from(spec.destChainId),
          spec.recipient,
          BigNumber.from(spec.originChainId),
          spec.originToken,
          BigNumber.from(spec.amount),
          spec.erc20Data,
          spec.depositor,
        ],
      ]
    )
  );
}

/** flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline)). */
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

/** Convenience: low-nullifier index for inserting `value` into the current tree (for commitSend). */
export async function lowNullifierIndexFor(tree: Contract, value: string, blockTag?: number): Promise<number> {
  const imt = await reconstructChainImt(tree, blockTag);
  return findLowNullifierIndex(imt.leaves, value);
}

// ── Proof builders ────────────────────────────────────────────────────────────────────────

/**
 * Well-formed placeholder for the `(root, timestamp)` L2->L1 message-inclusion proof. On the anvil
 * harness {MockL2MessageVerification} accepts any such message, so the batch / index / proof fields
 * are not inspected; the IMT layer and the `rootTimestamp` deadline check are what's verified.
 */
function messageProofPlaceholder(): {
  batchNumber: string;
  messageIndex: string;
  messageTxNumberInBatch: number;
  messageProof: string[];
} {
  return { batchNumber: "1", messageIndex: "0", messageTxNumberInBatch: 0, messageProof: [] };
}

/**
 * Build an {ImtInclusionProof} for `value` against `chainId`'s live IMT, carrying a root snapshot
 * timestamp of `rootTimestamp` (must be <= the flow deadline for `authorize` to accept it).
 */
export async function buildInclusionProof(params: {
  l2Tree: Contract;
  chainId: BigNumber | number | string;
  value: string;
  rootTimestamp: number;
  l2BlockTag?: number;
}): Promise<ImtInclusionProof> {
  const { l2Tree, chainId, value, rootTimestamp, l2BlockTag } = params;
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
    rootTimestamp: rootTimestamp.toString(),
    leaf: imt.leaves[idx],
    imtLeafIndex: idx,
    imtProof: imt.engine.merklePath(idx),
    ...messageProofPlaceholder(),
  };
}

/**
 * Build an {ImtNonInclusionProof} proving `value` is absent from `chainId`'s live IMT, carrying a
 * post-deadline root snapshot timestamp `rootTimestamp` (must be > the flow deadline for
 * `authorizeRefund` to accept it). O(log n) via the low-nullifier bracket.
 */
export async function buildNonInclusionProof(params: {
  l2Tree: Contract;
  chainId: BigNumber | number | string;
  value: string;
  rootTimestamp: number;
  l2BlockTag?: number;
}): Promise<ImtNonInclusionProof> {
  const { l2Tree, chainId, value, rootTimestamp, l2BlockTag } = params;
  const imt = await reconstructChainImt(l2Tree, l2BlockTag);
  const lowIndex = findLowNullifierIndex(imt.leaves, value); // throws if value present

  const onChainRoot: string = await l2Tree.root(l2BlockTag !== undefined ? { blockTag: l2BlockTag } : {});
  if (imt.root.toLowerCase() !== onChainRoot.toLowerCase()) {
    throw new Error(`off-chain IMT root ${imt.root} != on-chain root ${onChainRoot} for chain ${chainId.toString()}`);
  }

  return {
    sourceChainId: BigNumber.from(chainId).toString(),
    chainImtRoot: imt.root,
    rootTimestamp: rootTimestamp.toString(),
    lowLeaf: imt.leaves[lowIndex],
    lowLeafIndex: lowIndex,
    imtProof: imt.engine.merklePath(lowIndex),
    ...messageProofPlaceholder(),
  };
}

// ── Tuple encoders (ordered for ethers contract calls) ────────────────────────────────────

/** SendSpec tuple in struct field order (destChainId, recipient, originChainId, originToken, amount, erc20Data, depositor). */
export function specTuple(s: SendSpec): unknown[] {
  return [s.destChainId, s.recipient, s.originChainId, s.originToken, s.amount, s.erc20Data, s.depositor];
}

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
    p.rootTimestamp,
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
    p.rootTimestamp,
    p.messageTxNumberInBatch,
    p.messageIndex,
    p.messageProof,
    leafTuple(p.lowLeaf),
    p.lowLeafIndex,
    p.imtProof,
  ];
}
