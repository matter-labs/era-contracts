# The interop commitment tree

Each chain owns one **append-only Indexed Merkle Tree (IMT)**, the `L2InteropCommitmentTree`, a genesis
built-in at `0x10012`. It is the ledger of every atomic-flow leg that chain has ever committed: one
`commitValue` leaf per leg. Everything the finality and timeout proofs assert reduces to "this value is
present in / absent from this chain's IMT at this batch" (see {protocol-docs/atomicity/proofs.md}).

The **generic** indexed-Merkle-tree data structure — the `{value, nextIndex, nextValue}` leaf, the
low-nullifier non-membership technique, and the hashing rules — is documented once in
{protocol-docs/message-root.md#indexed-merkle-tree-indexedmerkletree} and implemented in
`l1-contracts/contracts/common/libraries/IndexedMerkleTree.sol`. This page covers only what is specific
to the atomic-interop use of it.

## Why an _indexed_ tree

The atomic flow needs both directions of proof against the same root:

- **Finality** needs to prove a leg's `commitValue` is **present** — a plain Merkle inclusion proof.
- **Timeout** needs to prove a leg's `commitValue` is **absent** — a non-membership proof.

A regular Merkle tree gives cheap membership but no cheap non-membership. An indexed tree stores its
leaves as a sorted singly-linked list (`{value, nextIndex, nextValue}`), so absence of `v` is proven by
exhibiting the one leaf whose `value < v < nextValue` (the _low nullifier_) — O(log n), same cost as
inclusion. That symmetry is the whole reason the timeout path needs no L1 coordinator: a refund is just
a non-membership proof against the same root the finality proof would have used.

## Append-only, and why it matters

`insert` only ever adds a leaf and relinks one predecessor; no leaf is ever removed or its `value`
changed. Two consequences the proofs lean on:

- **`begin(N) == end(N-1)`** — the tree root at the start of batch `N` equals its root at the end of
  batch `N-1`. The bootloader snapshots both (see below), and the timeout argument in
  {protocol-docs/atomicity/proofs.md#soundness} uses this identity to chain batches together.
- **Monotonic membership** — once a value is in the tree it stays in; a value absent at some batch
  boundary was absent at every earlier one. This is what makes a single well-chosen absence proof
  conclusive for "never committed in time."

Leaf-value rules inherited from `IndexedMerkleTree`, relevant here: the zero value is reserved
(`commitValue` is a keccak digest, so it is never zero in practice), duplicates revert
(`IMTValueAlreadyExists` — a `(flowId, bundleHash)` pair can be committed at most once), and empty tree
positions are padded with `IMT_EMPTY_LEAF_HASH` rather than `hashLeaf({0,0,0})` so a padded slot can
never be passed off as the `{0,0,0}` low leaf to forge a non-inclusion proof.

## `L2InteropCommitmentTree`

A thin, access-controlled wrapper over one `IMT` in storage:

- `insert(_value, _lowNullifierIndex)` — **appender-gated**: only the `AtomicFlowManager` (the
  `appender()` getter, a canonical fixed address) may insert, otherwise `CommitmentTreeNotAppender`.
  This is the sole mutator; the manager calls it from `append` with the leg's `commitValue` and the
  caller-supplied low-nullifier hint. Besides mutating the tree it publishes the leaf for DA and emits
  `RootUpdated` (see [below](#the-root-is-read-from-storage-never-published)).
- `root()`, `leafCount()`, `leafAt(_index)`, `merklePath(_index)` — read-only accessors used by the
  off-chain proof engine and tests to build inclusion / non-inclusion proofs. `leafCount()` counts the
  index-0 sentinel too.
- `initL2()` — **upgrader-gated**, one-shot: calls `IMT.setup`, reserving index 0 for the sentinel
  `{0,0,0}` leaf. Run during ZKsync OS genesis force-deployment (see
  {protocol-docs/atomicity/README.md#zksync-os-genesis}).

The contract has no constructor and no immutables (it is an L2 built-in); its appender is a constant
getter resolved to a fixed genesis address. Its `fallback` is a self-only reverting sink, used solely
as the gas-burn target described below.

## The root is read from storage, never published

The tree never publishes its **root**: no L2->L1 message carries it, and the `RootUpdated(leafIndex,
root)` event exists for off-chain indexing only. Instead the ZKsync OS bootloader reads the root
**directly from the contract's storage** at every batch boundary and commits two snapshots into the
batch's chain batch root: leaf 2 = the root at batch **begin**, leaf 3 = the root at batch **end** (see
{protocol-docs/message-root.md#chain-batch-root-zksync-os}). Those snapshots are what settle to the
settlement layer and get re-imported everywhere, and they are what the proofs authenticate against.

The tree's storage is therefore **consensus-critical**: the bootloader derives the root slot from the
position of the single `_imt` field (it reads the engine's `_height` from slot 0 and derives
`_nodes[_height][0]` from the `_nodes` base slot 2), and an uninitialized tree reads as `bytes32(0)`.
The layout must not be reorganized without a coordinated protocol change.

The **leaves**, by contrast, are published — that is what keeps the tree reconstructible from L1. Every
`insert` reports the inserted 32-byte value to the `INTEROP_COMMITMENT_LEAF_HOOK` system hook
(`0x7004`, in `l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol`), which ZKsync OS
records as an L2->L1 log; a rejecting hook reverts the insert with `InteropCommitmentLeafHookFailed`.
Only the values are logged, one per insert in insertion order — the `nextIndex`/`nextValue` links are
re-derivable from the sorted set, so the whole tree can be rebuilt from the log stream alone. Because
the mandatory L2->L1 log region is always committed to L1, this holds whatever DA configuration the
chain runs; the argument is in {protocol-docs/atomicity/security.md#data-availability}.

Ahead of the hook call the contract burns the EVM-gas equivalent of recording one log
(`L1MessageGasLib.estimateLogGas`, mirroring `L1Messenger.sendToL1`) by forwarding it to the self-only
reverting `fallback`; a leg that supplies too little gas reverts with `NotEnoughGasSupplied` rather than
committing a leaf whose log could not be paid for.
