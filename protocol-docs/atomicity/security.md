# Security model: guarantees, preconditions, and assumptions

This page collects the properties the atomic-interop flow provides, the ones it deliberately does not,
the on-chain preconditions the timeout proof relies on, and the trust assumptions of the current
release. The proof-level soundness/completeness arguments live in
{protocol-docs/atomicity/proofs.md#soundness}.

## Guarantees

- **Finalizability and refundability are mutually exclusive.** For a given flow, exactly one of the two
  outcomes is ever provable: either every leg is proven committed before the deadline (so any leg's
  destination _may_ execute), or a leg is proven absent past it (so committed legs _may_ be refunded) —
  never both. This follows from the mutual exclusivity of the finality and timeout conditions
  ({protocol-docs/atomicity/proofs.md#soundness}), and it is the guarantee the protocol actually
  enforces.

  This is deliberately weaker than "every destination call executes". The atomicity gate governs
  **whether execution is permitted**, not whether it happens: `requireFlowFinalized` proves all legs
  committed, but each destination is then driven independently by whoever submits
  `executeAtomicBundle`, and a bundle that only reached `Verified` can still be partially executed or
  have individual calls `Cancelled` through `unbundleBundle`
  ({protocol-docs/interop.md#unbundling-unbundlebundle}). What atomicity rules out is the dangerous
  asymmetry — a leg being burned on one chain while the flow is refunded on another — not
  under-execution by a passive or adversarial destination caller.

- **No back-dating.** A batch's settlement inclusion time `t` only ever rises, so a commit that lands
  late cannot be made to look in-time; the deadline check is monotone.
- **Timeout-proof liveness.** If a flow genuinely times out, a valid timeout proof can always be
  produced from any post-deadline aggregated root — including for a source chain that halts
  ({protocol-docs/atomicity/proofs.md#completeness}), provided the preconditions below hold. Note this is
  liveness of the _proof_, hence of `authorizeRefund`: it guarantees the legs become `Revertable`, not
  that `claimRefund` then succeeds in returning the assets (see the recovery non-guarantees below).
- **No trusted coordinator.** There is no L1 atomic contract and no global-root registry; finality and
  timeout are both proven against the ordinary interop-root channel. Nothing the tree emits is on the
  critical path either: the per-leaf L2->L1 logs exist purely for data availability (see
  [Data availability](#data-availability)) and are never read by any contract.

## Non-guarantees

- **Refunds are best-effort, and the claim is all-or-nothing.** `claimRefund` succeeds iff no attempted
  recovery reverts — the recovery calls have no failure containment, so one revert rolls the whole claim
  back, while a claim that recovers nothing still consumes the leg. "Best-effort" only means a sender may
  _decline_ a call it does not recognize (by returning `false`); it does not isolate failures between
  calls. Full refundability of an arbitrary bundle is not guaranteed, and a deterministically-reverting
  recovery can leave a leg permanently stuck at `Revertable`. Making a fund-moving leg recoverable, and
  its recovery robust, is the flow author's responsibility. See
  {protocol-docs/atomicity/recovery.md#non-guarantees}.
- **Indirect calls may not carry destination-side value.** `interopCallValue != 0` on an indirect call
  is rejected at send (`IndirectCallCannotCarryValue`): on the recovery path native value is returned to
  `InteropCall.from`, which for an indirect call is the starter contract (the asset router for
  router-produced calls) rather than the payer, so allowing it would strand funds. Direct calls may carry value — theirs is refunded to their own `from` through
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

## Known issues (to be fixed in this release)

1. **Refund consumption is per bundle, not per call.** `claimRefund` flips the whole leg to `Reverted`
   up front and then dispatches every call's recovery in one shot, ignoring the per-call
   `recoverAtomicCall` result. If any single call's recovery silently no-ops — e.g. a future router
   revision no longer recognizes an in-flight call's calldata encoding and returns `false` — that
   call's funds are permanently stranded while the rest of the bundle recovers (this is why the
   `IMPORTANT` note in `L2AssetRouter.recoverAtomicCall` requires every historical calldata format to
   stay recognized forever). The proper fix is to track the reverted status per call rather than per
   bundle, so a not-yet-recovered call stays claimable on its own.

## Known issues and accepted limitations

1. **Pre-v33 counterparty chains can still brick funds.** Atomic interop requires protocol version
   v33 or newer on every participating chain. If pre-v33 chains are allowed into the ecosystem, it is
   the **user's responsibility** to pick a counterparty chain that supports atomic interop (v33 or
   newer). The on-chain checks (`append`'s registered-source-chain check, the timeout-protocol
   preconditions above) may make it look like the protocol aims for funds never bricking — that is
   NOT the case: a leg sent towards, or declared from, a chain that never gained atomic-interop
   support can strand its funds.

2. **The "default" unbundler does not work for L2->L1 bundles.** For L2->L2 interop, a sender who
   sets no `unbundlerAddress` gets a working default: the attribute is pinned to the source chain id
   and sender, and the sender can always unbundle by making an L2->L2 interop call through the
   InteropCenter to the destination `L2InteropHandler`'s `receiveMessage` rescue path. For L2->L1
   bundles (withdrawals) that escape hatch does not exist: generic L2->L1 interop calls are not
   supported (only asset-router withdrawals are), so the default unbundler — pinned to the source L2
   chain id — can neither call `L1InteropHandler.unbundleBundle` directly (wrong chain id) nor reach
   it via `receiveMessage`. Unbundling on L1 is formally supported (an explicit `unbundlerAddress`
   with the L1 chain id, or the chain-wildcard form, works), but the default is broken.
   **Recommendation:** forbid unbundling on L1 entirely until normal L2->L1 interop calls are
   supported.

3. **A refund receiver that rejects the base token blocks its own claim.** On the timeout path, a
   direct value leg's refund pushes native base-token value to the call's `from`. A contract that
   (permanently or temporarily) rejects native-token transfers makes `claimRefund` revert until it
   can accept the transfer; the leg stays `Revertable` the whole time. Hard to fix without a
   pull-based escrow, but a potential footgun for contract senders.

4. **Bundle version is checked at verification, call versions only at execution.** `verifyBundle` /
   the atomic finality gate validate `InteropBundle.version`, but the per-call
   `InteropCall.version` fields are validated only when a call is actually executed
   (`_executeCalls`). A bundle whose calls carry a wrong version can therefore be verified — and
   cancelled via unbundling — yet never executed. This is considered acceptable: such a bundle can
   only be produced by a malformed sender, and cancellation remains available.

5. **Rotating an asset handler strands in-flight atomic burns.** Timeout recovery
   (`L2AssetRouter.recoverAtomicCall`) resolves the handler for the burned asset through the mutable
   `assetHandlerAddress` mapping at CLAIM time, while the burn used the handler registered at SEND
   time. If the registration is overwritten between the two (`setAssetHandlerAddress` /
   `setAssetHandlerAddressThisChain`), recovery of the in-flight burn is misrouted to the new
   handler: it may revert (blocking the refund until rotated back) or silently no-op (consuming the
   claim — the leg is marked `Reverted` regardless). Accepted for this release; both entry points
   carry a warning, and migrations should use a new asset id instead of re-pointing an existing one.

6. **Funds burned by a non-router indirect call starter are not recovered on timeout.**
   `_recoverBundle` dispatches per call on the local sender: the `recoverAtomicCall` hook fires only
   for `from == L2_ASSET_ROUTER_ADDR`, and the base-token path only for
   `from != L2_ASSET_ROUTER_ADDR && value != 0`. Yet any contract implementing `IL2CrossChainSender`
   can serve as an indirect call starter — `InteropCenter._processCallStarter` invokes
   `initiateIndirectCall` on the user-supplied `to` and stamps that address as `InteropCall.from` —
   and indirect calls force `interopCallValue == 0`. Whatever such a starter burned at send time
   (including the `indirectCallMessageValue` it was forwarded as `msg.value`) therefore matches
   neither branch: no reversal hook is called, no value is refunded, and `claimRefund` consumes the
   leg while silently skipping that call — the manager will never return those funds. A generic
   dispatch over `IAtomicRecoverable` senders is not safely possible today: `InteropCall` carries no
   direct/indirect marker, so the manager cannot tell an indirect starter (which should get the
   hook) from a direct call's `from` (possibly an EOA or a contract without the hook), and a
   reverting probe would block the whole claim (see
   {protocol-docs/atomicity/recovery.md#the-walk-is-all-or-nothing-not-per-call-isolated}); fixing
   this requires marking indirect calls in the bundle encoding. Restricting indirect starters to the
   asset router at send time was rejected too: every L2→L2 send is atomic (see
   {protocol-docs/interop.md#restrictions}), so the restriction would remove the
   `IL2CrossChainSender` extension point from interop entirely. Accepted for this release: only
   asset-router burns (and direct-call base-token `value`) are recovered by the manager. A custom
   starter that burns funds MUST ship its own permissionless recovery, gated on the manager's
   terminal leg state (`legState(flowId, bundleHash) == Reverted`, signalled by `FlowRefunded`) —
   relying on the manager's dispatch strands the burn.

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

- **Halted source chain.** A chain that stops settling after the deadline cannot block the _refund
  authorization_: the end-branch timeout proof anchors on the chain's last batch inside a post-deadline
  aggregated root, which precondition 1 guarantees exists, so `authorizeRefund` stays available and the
  legs on live chains become `Revertable`. Note this does not by itself return the assets — `claimRefund`
  is a separate conditional step, and legs committed on the halted chain itself cannot be claimed while
  it is down (its `AtomicFlowManager` is unreachable).
- **Reserved address `0x10013`.** Intentionally empty — it formerly held a global-root importer removed
  when atomic interop moved to the interop-root channel. It must stay reserved.
- **Stale bundle-hash prediction.** If an off-chain `bundleHash` preview goes stale (e.g. an upgrade
  changes bundle encoding), `append` reverts the send with the burn included, rather than committing an
  unfinalizable/unrefundable leg (see {protocol-docs/atomicity/flow.md#1-atomic-send-append}).
