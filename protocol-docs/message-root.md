# Message Root: Aggregation, Chain Batch Roots, and Interop Root Import

This document is the single source of truth for the message-root subsystem: how chain batch roots are aggregated into a global interop root, what a v32 chain batch root and batch leaf contain, the Indexed Merkle Tree (IMT) data structure, how aggregated roots are imported into chains and re-verified at batch execution, and how inclusion proofs traverse the whole structure.

For how atomic interop _consumes_ these primitives (commit values, finalize/timeout branches, soundness and completeness arguments), see {protocol-docs/atomicity/proofs.md}. That flow is documented there, not here.

Relevant contracts and libraries:

- `MessageRootBase`, `L1MessageRoot`, `L2MessageRoot` (`l1-contracts/contracts/core/message-root/`)
- `MessageHashing`, `ChainBatchRootTree`, `IndexedMerkleTree` (`l1-contracts/contracts/common/libraries/`)
- `ExecutorFacet`, `MailboxFacet` (`l1-contracts/contracts/state-transition/chain-deps/facets/`)
- `L2InteropRootStorage`, `L2MessageVerification` (`l1-contracts/contracts/interop/`)

## Aggregation structure

The `MessageRoot` contract (deployed as `L1MessageRoot` on L1 and `L2MessageRoot` on settlement-layer L2s such as Gateway) stores the cross-chain message roots of all registered chains and aggregates them into one root. From v31 onwards it also performs L2->L1 message verification directly, bypassing the `Mailbox` of individual chains.

The structure is a two-level Merkle forest plus a per-batch record:

1. **Chain tree** (`chainTree[chainId]`, a `DynamicIncrementalMerkle` append-only tree) — one per registered chain. Each leaf is a **batch leaf**: `MessageHashing.batchLeafHash(chainBatchRoot, batchNumber, l1Timestamp)`.
2. **Shared tree** (`sharedTree`, a `FullMerkle` tree) — one per settlement layer. Leaf `chainIndex[chainId]` is the **chain-id leaf**: `MessageHashing.chainIdLeafHash(chainRoot, chainId)`, where `chainRoot` is the current root of that chain's chain tree. The shared tree root is the **aggregated root** (also called the **interop root**), returned by `getAggregatedRoot`.
3. **Flat batch record** (`chainBatchRoots[chainId][batchNumber]`) — the same chain batch root values as the chain-tree leaves, stored individually for message verification, plus `chainBatchRootTimestamp[chainId][batchNumber]` so off-chain proof builders can recover the exact `l1Timestamp` folded into each batch leaf.

Leaf hash domains are separated by paddings: `BATCH_LEAF_PADDING = keccak256("zkSync:BatchLeaf")` and `CHAIN_ID_LEAF_PADDING = keccak256("zkSync:ChainIdLeaf")`.

Both trees use the same empty-entry hash, the keccak256 of 96 zero bytes (`0x46700b…8c21`): `CHAIN_TREE_EMPTY_ENTRY_HASH` and `SHARED_ROOT_TREE_EMPTY_HASH` in `IMessageRoot.sol`.

### Chain registration

`addNewChain(chainId, startingBatchNumber)` (Bridgehub or ChainAssetHandler only) assigns the next `chainIndex`, seeds an empty chain tree, pushes a `chainIdLeafHash(bytes32(0), chainId)` leaf into the shared tree, and sets `currentChainBatchNumber[chainId] = startingBatchNumber`. Index 0 is reserved for the chain the contract itself is deployed on. During settlement-layer migration, `setMigratingChainBatchNumber` moves the batch counter to the new layer so consecutive numbering is preserved.

### `historicalRoots` and interop-root events

Every shared-tree update records `historicalRoots[block.number] = StoredInteropRoot({root, timestamp})` — the `(blockNumber, root, timestamp)` tuple that chains later import (see below) and that the executor double checks at batch execution. Properties:

- A block may contain several updates; the **final** root of a block is always safe to use, since each new root cumulatively aggregates all prior ones.
- The `timestamp` is `block.timestamp` at write time. Time-sensitive proofs (e.g. the atomic-interop timeout protocol) rely on it to show a root was created after a deadline.
- Storage compatibility with v31: interop was not enabled in v31, so this mapping (and the chain trees) were empty on L1 at upgrade time — no backfill needed. Extending the mapping value from `bytes32` to the `StoredInteropRoot` struct is layout-safe because mapping values live at hashed locations and `root` occupies the original slot.

Each update also emits `NewInteropRoot(chainId, blockNumber, logId, timestamp, sides)`. `sides` has length 1 and holds only the root (proof-based interop; pre-commit interop will later add real tree sides). `logId` (`interopRootLogId`) increments **at most once per block**: all emissions within one block share the same `logId` so the server can group them; it counts starting from v31 only.

## v31 vs v32 append flows

Two entry points exist on `MessageRootBase`, both restricted to the chain's own diamond (its `ExecutorFacet` calls them directly while settling; asset correctness across chains is guaranteed by ZK proofs):

- **`addChainBatchRoot`** — the v31 flow, record-only. It runs the shared validation (chain registered, root non-zero, not yet recorded, batch number exactly `currentChainBatchNumber + 1`) and stores the root in `chainBatchRoots`, but does **not** touch the chain tree or shared tree. Kept so pre-upgrade (v31) executor facets continue to work; `currentChainBatchNumber` still advances, so numbering continues seamlessly once the chain upgrades.
- **`addChainBatchRootV32`** — the v32 flow: same recording, then the interop half:
  1. `l1Timestamp = block.timestamp` is stored in `chainBatchRootTimestamp` and folded into the batch leaf via `MessageHashing.batchLeafHash(chainBatchRoot, batchNumber, l1Timestamp)`. Binding the timestamp into the leaf makes the settlement timestamp provable by the same inclusion proof as the root — a single aggregated root proves many chain batch roots, each with its own settlement time.
  2. The batch leaf is pushed into `chainTree[chainId]` (event `AppendedChainBatchRoot`).
  3. The chain's shared-tree leaf is updated to `chainIdLeafHash(newChainRoot, chainId)` (event `NewChainRoot`).
  4. The new shared root is emitted (`NewInteropRoot`) and recorded in `historicalRoots`.

Only v32 executors call the v32 entry point, so the interop trees contain v32-format roots exclusively — a non-empty chain tree implies the chain uses the current chain-batch-root format. On both L1 and Gateway the executor appends the committed `l2LogsTreeRoot` via `addChainBatchRootV32` (`ExecutorFacet._appendMessageRoot`); on Gateway that value is already the chain batch root (it commits to an empty multichain batch root), so the paths are identical and no per-batch log reconstruction or balance accounting is performed.

## Chain batch root (ZKsync OS)

For a ZKsync OS chain, the chain batch root — the value committed as the batch's `l2LogsTreeRoot` — is itself a fixed height-3 (8-leaf) keccak256 Merkle tree, mirrored bit-for-bit by `ChainBatchRootTree` (Solidity) and `compute_chain_batch_root` (zksync-os bootloader):

| Leaf | Content                                                                                |
| ---- | -------------------------------------------------------------------------------------- |
| 0    | L2 logs tree root (the batch's local L2->L1 logs tree)                                 |
| 1    | multichain root (the chain's own aggregated `MessageRoot`; empty for now)              |
| 2    | interop commitment tree (IMT) root **at batch begin** — before the batch's first block |
| 3    | interop commitment tree (IMT) root **at batch end** — after the batch's last block     |
| 4–7  | reserved (zero)                                                                        |

Internal nodes are `keccak256(left || right)`; leaves are used directly (no leaf-hashing step). The all-zero right subtree is the constant `RESERVED_SUBTREE_NODE`, so the root is computable from the four live leaves in 3 keccaks, and the reserved leaves can later be populated in place without changing the tree shape.

The IMT snapshots (leaves 2 and 3) are what make a chain's interop-commitment-tree root provable on other chains: an authenticated chain batch root proves either leaf with a 3-sibling path. The bootloader reads both snapshots directly from `L2InteropCommitmentTree` storage — the tree contract never publishes the root itself (it does log each inserted leaf for DA; see {protocol-docs/atomicity/imt.md}). How these snapshots drive finalize/timeout verification is covered in {protocol-docs/atomicity/proofs.md}.

### Genesis root and `seedGenesisRoot`

`ChainBatchRootTree.genesisChainBatchRoot()` is the chain batch root of batch 0: zero logs root, zero multichain root, and `EMPTY_IMT_ROOT` (the root of a freshly seeded IMT — the hash of the `{0,0,0}` sentinel leaf, i.e. keccak256 of 96 zero bytes) at both batch boundaries.

Freshly created ZKsync OS chains get this genesis root into the aggregation structure at creation time: the chain stores it as `l2LogsRootHash(0)` in its DiamondInit, and the Bridgehub calls `MessageRootBase.seedGenesisRoot(chainId)` right after registration within the same `createNewChain` transaction. `seedGenesisRoot`:

- is a no-op for EraVM chains;
- requires the chain to be registered with `currentChainBatchNumber == 0` and no batch-0 root recorded — this rules out chains onboarded at a non-zero starting batch and chains that already pushed real batches;
- records the root under batch 0 and pushes it into the interop trees via the v32 push path, while `currentChainBatchNumber` stays 0 so the first real batch continues at 1.

The contract never computes a chain's batch-root format itself — the chain always reports its own roots. Chains registered at a non-zero `startingBatchNumber` (already-deployed chains, settlement-layer migrations) never get a genesis leaf; such chains must settle at least one batch on the layer before they can be registered for interop, enforced by `ChainRegistrationSender`. Consequence: every chain interop can target has at least one batch leaf inside the shared root (`chainTreeLeafCount(chainId) > 0`) — a precondition of the atomic-interop timeout protocol.

## Indexed Merkle Tree (`IndexedMerkleTree`)

The IMT is the shared engine for membership **and non-membership** proofs; `L2InteropCommitmentTree` is its on-chain instance. Structure:

- Each leaf preimage is `IMTLeaf {value, nextIndex, nextValue}`. Across all leaves, these fields form a sorted singly linked list over the inserted values.
- Storage (`IMT`): a `FullMerkle` tree of leaf hashes, `leaves[index]` full preimages for sorted-list updates, and `valueToIndex[value]` to reject duplicates.
- `hashLeaf` is `keccak256(abi.encode(value, nextIndex, nextValue))` — a 96-byte preimage, deliberately not 64 bytes, so a crafted proof cannot start from an intermediate node.
- `setup` reserves index 0 for the `{0,0,0}` sentinel head leaf. Empty (padded) positions use `IMT_EMPTY_LEAF_HASH = keccak256("zkSync:IndexedMerkleTree:emptyLeaf")` — deliberately **not** a valid `hashLeaf` output, so a padded index can't be presented as a `{0,0,0}` low leaf to forge non-inclusion. The off-chain imt-engine must use the same padding value.
- `insert(value, lowLeafIndex)`: the caller supplies the index of the **low leaf** (the leaf expected to precede `value` in sorted order). Zero and duplicate values are rejected. If the hint is stale, the function walks the linked list forward up to `MAX_LOW_INDEX_SEARCH_ATTEMPTS` (5) hops. The low leaf's `nextIndex`/`nextValue` are re-pointed at the new leaf, which inherits the old successors; the tree is append-only (leaves are never removed).
- `verifyInclusion(root, value, leaf, leafIndex, proof)` — membership: check `leaf.value == value` and the Merkle path.
- `verifyNonInclusion(root, value, lowLeaf, lowLeafIndex, lowLeafProof)` — non-membership via the **low-nullifier** technique: prove a leaf with `lowLeaf.value < value` and (`lowLeaf.nextValue == 0` or `lowLeaf.nextValue > value`) is in the tree; the sorted-linked-list invariant then implies `value` is absent.

Because the tree is append-only and the bootloader snapshots its root at every batch boundary, `begin(N) == end(N-1)`, and non-membership at a later snapshot implies non-membership at all earlier ones — the property the atomic-interop timeout branches build on ({protocol-docs/atomicity/proofs.md#timeout}).

## Interop-root import and the batch-execution double check

Aggregated roots produced on a settlement layer reach consumer chains as follows:

1. **Import (L2 side).** The bootloader (and only the bootloader) calls `L2InteropRootStorage.addSingleInteropRoot` / `addInteropRootsInBatch` with `InteropRoot {chainId, blockOrBatchNumber, timestamp, sides}` structs. The contract stores `storedInteropRoots[chainId][blockOrBatchNumber] = StoredInteropRoot({root: sides[0], timestamp})`, i.e. the full `(blockOrBatchNumber, root, timestamp)` tuple, readable via `interopRoots(chainId, blockOrBatchNumber)`. Enforced invariants: `sides.length == 1` (proof-based interop — the array holds only the root); the root is non-zero; the timestamp is non-zero (so a zero stored timestamp structurally means "nothing imported at this key"); no overwrite of an existing entry. `blockOrBatchNumber` is a block number in proof-based/pre-commit interop and a batch number in commit-based interop. This logic requires the timestamp-carrying bootloader entry points and is therefore ZKsync OS-only (not EraVM-compatible); no roots imported under earlier protocol versions exist, since interop was not activated in v31.

2. **Double check (settlement-layer side).** When the importing chain's batch is executed, `ExecutorFacet._verifyDependencyInteropRoots` re-derives every imported root: for `interopRoot.chainId == block.chainid` (the only supported case this release — roots are imported from the settlement layer the chain settles on, L1 only) it reads `messageRoot.historicalRoot(blockOrBatchNumber)` and requires both the root (`InvalidMessageRoot`) and the timestamp (`InvalidInteropRootTimestamp`) to match; any other chain id reverts with `CommitBasedInteropNotSupported`. The verified tuples are folded into a rolling hash over `(chainId, blockOrBatchNumber, timestamp, sides)` that must equal the committed batch's `dependencyRootsRollingHash` (`DependencyRootsRollingHashMismatch` otherwise). An imported root and its timestamp are therefore exactly as trustworthy as the settlement layer's own record.

## Proof paths

All verification goes through `MessageHashing._getProofData` (exposed as `MessageRoot.getProofData`), which parses a proof of the following shape. `_proof[0]` is metadata (new format, version byte `0x01`): `[version | logLeafProofLen | batchLeafProofLen | finalProofNode | zeros…]`; the old format (a plain Merkle path) is still accepted for backward compatibility and implies `finalProofNode = true`.

**Hop 1 — log leaf to batch root.** The leaf (an L2 log/message hash, rejected if it equals the default leaf) plus `logLeafProofLen` siblings and the leaf mask yield `batchSettlementRoot`.

- If `finalProofNode` is set, verification terminates here against the verifier's local record:
  - On the settlement layer (`MessageRootBase._proveL2LeafInclusionRecursive`): the root must equal the recorded `chainBatchRoots[chainId][batchNumber]` (never the layer's own aggregate root). Batch 0 is not provable (`BatchZeroNotAllowed`). If no root is recorded, `_noBatchFallback` applies: on L1, batches produced before the chain's `v31UpgradeChainBatchNumber` are looked up on the chain itself via `l2LogsRootHash` (trust-bounded: a malicious chain can only damage itself while L1 is the only settlement layer; once the ZKsync OS CTM's ownership is transferred to decentralized governance, the chain-reported pre-v31 batch root can be trusted completely — until then the assumption is that no ZKsync OS-based Gateway exists); on L2 it returns 0, since newer implementations guarantee all available batch roots are stored.
  - On an L2 consumer (`L2MessageVerification`): the root must equal the imported `interopRoots(chainId, blockOrBatchNumber).root` — an L2 has no per-chain roots, only imported aggregate roots.

**Hop 2 — batch leaf to chain root.** For non-final proofs the next words are `[l1Timestamp][batchLeafProofMask][batchLeafProofLen siblings]`. The verifier reconstructs the batch leaf as `batchLeafHash(batchSettlementRoot, batchNumber, l1Timestamp)` — a wrong timestamp makes the leaf mismatch the tree, which is what authenticates the proof-supplied timestamp — and hashes up to the chain root of `chainTree[chainId]`. `MessageHashing.readAggregationHopPath` is the single accessor for this section's word layout (mask + siblings); its output is trustworthy only after the same proof bytes passed the leaf verifier.

**Hop 3 — chain-id leaf to aggregated root.** The chain root becomes `chainIdLeafHash(chainRoot, chainId)`, followed by two words: packed `(settlementLayerBatchNumber << 128 | settlementLayerBatchRootMask)` and `settlementLayerChainId`. `MessageHashing.readSettlementLayerReference` is the single accessor for these settlement-layer words (plus the hop-2 `l1Timestamp`); like its hop-2 sibling, its output is trustworthy only after the same proof bytes passed the leaf verifier. Verification recurses with the chain-id leaf as the new leaf: on L1, `L1MessageRoot` first checks the claimed settlement layer via `IL1ChainAssetHandler.isValidSettlementLayer`; on L2, the recursion anchors in the imported aggregate root, using the settlement layer's **block** number as `blockOrBatchNumber`. Recursion depth is capped at 1 (`DepthMoreThanOneForRecursiveMerkleProof`) — at most a single intermediate Gateway between the chain and L1.

Full path, innermost to outermost:

```
L2 log leaf
  -> (log-leaf siblings)          chain batch root            [leaf 0..3 of ChainBatchRootTree if ZKsync OS]
  -> batchLeafHash(+batchNumber, +l1Timestamp)
  -> (batch-leaf siblings)        chain tree root
  -> chainIdLeafHash(+chainId)
  -> (shared-tree siblings)       aggregated root == historicalRoot / imported interopRoots entry
```

The same aggregated-root anchoring, with `l1BatchTimestamp` read from the verified proof words and the chain-batch-root tree opened at IMT leaves 2/3, is how atomic interop authenticates IMT roots and settlement times — see {protocol-docs/atomicity/proofs.md}.
