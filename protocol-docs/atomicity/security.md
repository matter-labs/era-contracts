# Security model: guarantees, preconditions, and assumptions

This page collects the properties the atomic-interop flow provides, the ones it deliberately does not,
the on-chain preconditions the timeout proof relies on, and the trust assumptions of the current
release. The proof-level soundness/completeness arguments live in
{protocol-docs/atomicity/proofs.md#soundness}.

## Guarantees

- **All-or-nothing execution.** A flow either finalizes (every leg's destination executes) or unwinds
  (committed legs are refunded); a leg can never both finalize and be refunded. This follows from the
  mutual exclusivity of the finality and timeout conditions
  ({protocol-docs/atomicity/proofs.md#soundness}).
- **No back-dating.** A batch's settlement inclusion time `t` only ever rises, so a commit that lands
  late cannot be made to look in-time; the deadline check is monotone.
- **Refund liveness.** If a flow genuinely times out, a valid timeout proof can always be produced from
  any post-deadline aggregated root — including for a source chain that halts
  ({protocol-docs/atomicity/proofs.md#completeness}), provided the preconditions below hold.
- **No trusted coordinator.** There is no L1 atomic contract and no global-root registry; finality and
  timeout are both proven against the ordinary interop-root channel. Nothing the tree emits is on the
  critical path either: the per-leaf L2->L1 logs exist purely for data availability (see
  [Data availability](#data-availability)) and are never read by any contract.

## Non-guarantees

- **Refunds are best-effort.** A refund succeeds if at least one call recovered; full refundability of
  an arbitrary bundle is not guaranteed. Making a fund-moving leg recoverable is the flow author's
  responsibility. See {protocol-docs/atomicity/recovery.md#non-guarantees}.
- **Indirect calls may not carry destination-side value.** `interopCallValue != 0` on an indirect call
  is rejected at send (`IndirectCallCannotCarryValue`): on the recovery path native value is returned to
  `InteropCall.from`, which for an indirect call is the asset router rather than the payer, so allowing
  it would strand funds. Direct calls may carry value — theirs is refunded to their own `from` through
  the base-token recovery path (see
  {protocol-docs/atomicity/recovery.md#\_recoverbundle-reversing-the-burns}).
- **L1 destinations are rejected.** An atomic bundle is never published to L1, so it could only ever
  time out; and L2->L1 withdrawal accounting must stay append-only and never revertable (see
  {protocol-docs/bridging.md#security-notes}).

## Timeout-protocol preconditions

The timeout proof relies on three preconditions, each enforced on chain:

1. **Every chain interop can target has at least one batch inside the settlement layer's message root.**
   Enforced at two points:
   - Freshly created chains report their genesis batch root right after registration, in the same
     `createNewChain` transaction: the chain's DiamondInit stores
     `ChainBatchRootTree.genesisChainBatchRoot()` (batch 0 has no logs and a freshly seeded IMT, so the
     value is exact) as the batch-0 `l2LogsRootHash`, and the Bridgehub calls
     `MessageRootBase.seedGenesisRoot`, which pulls it from the chain's getters (once-only, fresh ZKsync
     OS chains only). See {protocol-docs/message-root.md#genesis-root-and-seedgenesisroot}.
   - Already-deployed chains onboarded with a non-zero starting batch number are NOT seeded (a real
     batch with that number exists elsewhere, and a synthetic leaf would diverge from it); instead
     `ChainRegistrationSender` refuses to register a chain for interop until it has settled at least one
     batch into the message root (`MessageRootBase.chainTreeLeafCount > 0`, else
     `ChainHasNoBatchesInMessageRoot`).

   This guarantees the "last batch inside the aggregated root" required by the end-branch (halted-chain)
   timeout proof always exists, even for a chain that halts before settling anything.

   Settlement-layer migration registers the chain on the new layer's message root with an empty tree;
   this is acceptable under the current assumption that only the **L1** message root anchors timeout
   proofs (see [Trust assumptions](#trust-assumptions) and the `IMPORTANT` note in
   `ChainAssetHandlerBase._bridgeMint`).

2. **Interop only involves registered chains.** An unregistered chain has no chain-id leaf in the
   settlement layer's aggregated shared tree (`MessageRootBase.sharedTree`), so no proof — finality or
   timeout — can be verified against it: every proof path terminates in the chain's chain-id leaf inside
   an imported aggregation root. Interop towards a chain must therefore only be enabled once the chain is
   registered (has its `sharedTree` leaf) AND has a batch in its chain tree (precondition 1) — exactly
   what the `ChainRegistrationSender` gate checks, and what `AtomicFlowManager.append` re-checks for
   every co-leg's declared source chain (see {protocol-docs/atomicity/flow.md#1-atomic-send-append}).

3. **Every batch leaf carries the timestamp at which it entered the shared root.** Enforced by
   `MessageRootBase.addChainBatchRootV32`, which folds the settlement-layer `block.timestamp` into the
   batch leaf (`MessageHashing.batchLeafHash`); the timestamp (`t`) is therefore proven by the same
   inclusion proof that authenticates the IMT root. Aggregated roots additionally carry their own
   creation timestamp (`T`) — one `(blockNumber, root, timestamp)` tuple exposed by
   `MessageRootBase.historicalRoot` on the settlement layer, imported into
   `L2InteropRootStorage.interopRoots` and double-checked at batch execution — which anchors the "root
   from after the deadline" requirement. See the two clocks in
   {protocol-docs/atomicity/proofs.md#two-authenticated-clocks}.

## Trust assumptions

- **L1-only settlement (this release).** Every flow's `settlementLayerChainId` must be the L1 chain id;
  `AtomicFlowManager` re-checks this wherever the settlement layer is consumed (`append`, finality,
  refund). Anchoring timeout proofs only on the L1 message root is what makes the settlement-layer
  migration case in precondition 1 acceptable. Extending atomic interop to gateway-settled flows would
  require revisiting that migration argument.
- **Honest majority / valid settlement.** The proofs are only as trustworthy as the imported interop
  roots and the settlement-layer batch execution that double-checks them; atomic interop adds no trust
  assumption beyond what the interop-root channel already requires
  ({protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}).

## Data availability

Only the IMT **root** travels through the chain batch root, but a refund claimant needs the tree's
**contents**: an inclusion or non-inclusion proof is built from the leaf set. If a source chain halts or
its operator withholds state, that leaf set must still be recoverable from L1 alone — otherwise a
halted chain could strand flows precisely in the case the timeout protocol exists to cover.

The IMT leaves are therefore published unconditionally: every `L2InteropCommitmentTree.insert` records
the inserted value as an L2->L1 log through `INTEROP_COMMITMENT_LEAF_HOOK`
({protocol-docs/atomicity/imt.md#the-root-is-read-from-storage-never-published}). The mandatory L2->L1
log region is part of every batch's committed pubdata, so this does not depend on the chain's DA
configuration — neither on the commitment _mechanism_ (`L2DACommitmentScheme`: calldata-keccak vs blobs)
nor on the committed _scope_ (`PubdataContent`). Even a chain running `PubdataContent.LOGS_ONLY`, which
commits only the log region and leaves state diffs and message preimages to the operator's discretion,
keeps its full leaf set on L1. Both enums live in `system-contracts/contracts/Constants.sol` (re-exported
from `l1-contracts/contracts/common/Config.sol`); `pubdataContent` is held in the chain's diamond storage
and committed into the ZKsync OS batch public input via the chain-config hash, so the settlement layer
enforces the configured mode rather than trusting the operator.

The tree structure itself adds nothing to publish: the values are logged in insertion order, and the
`nextIndex`/`nextValue` links of an indexed tree are a function of the sorted value set, so replaying the
logs reproduces the tree — and hence every root snapshot the proofs authenticate against — exactly.

## Edge cases

- **Halted source chain.** A chain that stops settling after the deadline still cannot strand a flow:
  the end-branch timeout proof anchors on the chain's last batch inside a post-deadline aggregated root,
  which precondition 1 guarantees exists.
- **Reserved address `0x10013`.** Intentionally empty — it formerly held a global-root importer removed
  when atomic interop moved to the interop-root channel. It must stay reserved.
- **Stale bundle-hash prediction.** If an off-chain `bundleHash` preview goes stale (e.g. an upgrade
  changes bundle encoding), `append` reverts the send with the burn included, rather than committing an
  unfinalizable/unrefundable leg (see {protocol-docs/atomicity/flow.md#1-atomic-send-append}).
