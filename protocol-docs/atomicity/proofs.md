# The atomic-interop proof system

> This page is the **canonical specification** of the atomic-interop finality and timeout conditions and
> their soundness/completeness arguments. The `AtomicInteropProof` library
> (`atomic-interop/libraries/AtomicInteropProof.sol`) implements it and its header points here.

Cross-chain authentication for the atomic flow reduces to one question asked against a source chain's
commitment tree (see {protocol-docs/atomicity/imt.md}): **is a leg's `commitValue` present in
(finality) or absent from (timeout) the tree, as of a batch that settled within / past the deadline?**
Both directions use the same claimed IMT root, authenticated the same way; they differ only in which
IMT root leaf and which timestamp comparison they use.

## Two authenticated clocks

Everything is timed against the flow `deadline` (a settlement-layer timestamp). Two clocks are compared
to it, and both are as trustworthy as the root they ride with — neither is a caller-supplied field:

- **`t` (`l1BatchTimestamp`)** — when the batch root was aggregated into the settlement layer's shared
  root. It is folded into the chain batch leaf, so it is proven by the _same_ inclusion proof that
  authenticates the IMT root, and re-parsed from `settlementProof`
  (see {protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}).
- **`T`** — the imported aggregation root's own creation time, stored alongside the root in
  `L2InteropRootStorage.interopRoots(slChainId, slBlock)` and double-checked on the settlement layer at
  batch execution.

## Root authentication (shared by both directions)

`_authenticateRoot` establishes that a claimed `chainImtRoot` really is chain `sourceChainId`'s batch
begin/end IMT snapshot, and hands back the settlement metadata:

- The claimed root is proven to be **chain-batch-root leaf `_imtRootLeafIndex`** — `2` = batch begin,
  `3` = batch end (`ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX` / `IMT_END_ROOT_LEAF_INDEX`) — of
  `(sourceChainId, batchNumber)`, via `L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared` against an
  imported interop root.
- The chain-batch-root path length is required to be **exactly `ChainBatchRootTree.TREE_DEPTH`**. This
  exact-depth check is load-bearing: without it a longer path could descend _into_ the IMT (whose
  internal nodes hash the same way) and pass off an IMT-internal node as "the root," against which a
  crafted low-nullifier leaf could fake non-inclusion of a value that is actually committed.
- The same proof bytes (same leaf, same mask) are re-parsed for the settlement-layer metadata
  (`slBlock`, `slChainId`, `l1BatchTimestamp` = `t`), so the parse is bound to the verified root. A
  single-level "final node" proof carries no settlement-layer batch reference (neither `t` nor the
  deadline could be checked), so it is rejected (`ProofMissingSettlementLayerBatch`).

The `provesAgainstBeginRoot` selector in `ImtProof` is a bool, not a raw leaf index, so authentication
can only ever target leaf 2 or leaf 3 — never the logs or multichain leaves of the chain batch root.

## Finality

> **A leg FINALIZES iff its `commitValue` is present in the batch-END IMT root (leaf 3) of a batch with
> `t <= deadline`, on the flow's settlement layer.**

`verifyInclusion` authenticates the root as the batch-**end** leaf, requires `slChainId ==
settlementLayerChainId` and `t <= deadline` (`ProofDeadlineExceeded` otherwise), and then runs a plain
IMT membership proof for `commitValue`. Because a batch's inclusion time `t` only ever rises, a commit
cannot be back-dated to look in-time after the fact.

Inclusion is **self-binding**: `commitValue` bakes in the chain-specific `bundleHash`, so it can only
ever exist in — and pass a membership proof against — its true source chain's tree. The source-chain
check on the finality path is therefore defense-in-depth; on the timeout path it is load-bearing (below).

## Timeout

> **A leg TIMES OUT (is refundable) via an aggregated root created strictly after the deadline
> (`T > deadline`) plus one batch of the source chain inside that root.**

The prover declares the branch (`ImtProof.provesAgainstBeginRoot`), which `verifyTimeoutAbsence`
validates against the authenticated `t` — no unverified value drives control flow. Both branches first
require `T > deadline` (`ProofInteropRootNotAfterDeadline`; and `T != 0`, i.e. the root was actually
imported) and `slChainId == settlementLayerChainId`, then a non-inclusion (low-nullifier) proof of
`commitValue`:

- **Begin branch** (`t > deadline` required): the value is absent from the batch-**begin** IMT root
  (leaf 2). The tree is append-only and `begin(N) == end(N-1)`, so absence at the begin of a late batch
  means absence from every batch with `t <= deadline`.
- **End branch** (`t <= deadline` required): the batch is _additionally_ proven to be the chain's
  **last** batch inside the aggregated root (`_verifyLastBatchInRoot`: wherever the batch-leaf path node
  is a left child, its right sibling must be the empty-subtree hash of the `DynamicIncrementalMerkle`
  zero cascade), and the value is absent from its batch-**end** IMT root (leaf 3) — the final IMT state
  reachable in time, since any later batch has `t' >= T > deadline`. This branch restores refund
  liveness for a source chain that **halts** and never settles a post-deadline batch; the required
  "last batch" always exists (see {protocol-docs/atomicity/security.md#timeout-protocol-preconditions}).

The absence proof is bound to the missing leg's declared source chain by the caller
(`authorizeRefund` checks `sourceChainId == legSourceChainIds[i]`). This binding is essential: a
`commitValue` is trivially absent from _any other_ chain's tree, so an unbound absence proof would let a
finalized flow be refunded too — a double-mint. Non-inclusion is not self-binding the way inclusion is,
which is exactly why the source chain must be checked explicitly here.

## Soundness

Both timeout branches are **mutually exclusive with finalization**. A value committed in a batch `B`
with `t_B <= deadline` is contained in:

- `begin(L)` of every batch `L` with `t_L > deadline` (batch order follows aggregation-time order) — so
  the begin branch cannot succeed for it; and
- `end(L')` of the last batch `L'` of any root with `T > deadline >= t_B` (that root already contains
  `B`, so `L' >= B`) — so the end branch cannot succeed for it.

Hence no value that satisfies the finality condition can also produce a valid timeout proof, and vice
versa: a flow is either finalizable or refundable, never both.

## Completeness

If a leg has really timed out, a valid timeout proof can **always** be produced from _any_ aggregated
root with `T > deadline`, even if the source chain inserts the value later:

- if the root contains a batch with `t > deadline`, the **first** such batch works — its begin root
  equals the end root of the last in-time batch, and the value is absent there (begin branch);
- otherwise the chain's last batch in the root is in time, and its end root — the final in-time IMT
  state — cannot contain the value either (end branch).

So refund liveness does not depend on catching any particular root; any post-deadline root suffices.

## Error surface

The revert reasons are declared in `atomic-interop/AtomicInteropErrors.sol`; the load-bearing ones:
`ProofInvalidChainBatchRootDepth` (exact-depth guard), `ProofDeadlineExceeded` (finality `t > deadline`),
`ProofInteropRootNotAfterDeadline` / `ProofSettlementLayerInteropRootNotImported` (`T` guard),
`ProofTimeoutBranchMismatch` (declared branch vs authenticated `t`), `ProofNotLastBatchInRoot`
(end-branch last-batch check), `ProofSettlementLayerMismatch` / `ProofSourceChainMismatch` (binding),
and `ProofInclusionFailed` / `ProofNonInclusionFailed` (the IMT proofs themselves).
