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
  `appender()` getter, a canonical fixed address) may insert. This is the sole mutator; the manager
  calls it from `append` with the leg's `commitValue` and the caller-supplied low-nullifier hint.
- `root()`, `leafCount()`, `leafAt(_index)`, `merklePath(_index)` — read-only accessors used by the
  off-chain proof engine and tests to build inclusion / non-inclusion proofs.
- `initL2()` — **upgrader-gated**, one-shot: calls `IMT.setup`, reserving index 0 for the sentinel
  `{0,0,0}` leaf. Run during ZKsync OS genesis force-deployment (see
  {protocol-docs/atomicity/README.md#zksync-os-genesis}).

The contract has no constructor and no immutables (it is an L2 built-in); its appender and all other
collaborators are constant getters resolved to fixed genesis addresses.

## The root is read from storage, never published

The commitment tree **publishes nothing** — no L2->L1 message, no event carrying the root. Instead the
ZKsync OS bootloader reads the tree's root **directly from its storage slot** at every batch boundary
and commits two snapshots into the batch's chain batch root: leaf 2 = the root at batch **begin**, leaf
3 = the root at batch **end** (see {protocol-docs/message-root.md#chain-batch-root-zksync-os}). Those
snapshots are what settle to the settlement layer and get re-imported everywhere, and they are what the
proofs authenticate against.

Two things follow:

- The tree's storage is **consensus-critical**: its slot layout is part of what the bootloader reads,
  so it must not be reorganized without a coordinated protocol change.
- Because the root travels through the chain batch root, the IMT contents must be reconstructible from
  L1 data alone. Atomic-interop chains therefore use the `L2_TO_L1_ONLY` DA scheme
  (`CalldataL1DAValidatorZKsyncOS`), which publishes the L2->L1 region as permanent L1 calldata — see
  {protocol-docs/atomicity/security.md#data-availability}.
