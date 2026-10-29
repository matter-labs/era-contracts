# Expiry of single-leg flows

A single-leg flow, such as a plain transfer, commits its only leg at send. Its leg can never be proven absent, so
the timeout refund ({protocol-docs/atomicity/recovery.md}) never applies to it. If executing the leg on the
destination always reverts, the value collected at send is never minted there and never returned. Typical causes:

- the destination token refuses the recipient (frozen, no longer allowlisted);
- a call with `value` targets an address without `receiveMessage`, such as any EOA;
- the call is malformed.

Expiry lets the destination decide that such a leg will never execute, and the source refund it against that
decision. It is opt-in per flow and limited to single-leg flows: in a multi-leg flow, refunding one leg after
another may already have executed would break atomicity.

## Opting in

- **Per flow.** A flow opts in with preimage version `ATOMIC_FLOW_EXPIRABLE_PREIMAGE_VERSION` (`0x02`). The field
  set is the same as version `0x01`, so the `AtomicFinalityProof` ABI and every selector taking it are unchanged.
  Version `0x02` requires exactly one leg (`ManagerExpirableFlowNotSingleLeg`), checked in
  `_validateAndComputeFlowId` so that append, finalize, expiry and refund agree
  ({protocol-docs/atomicity/flow.md#the-preimage-version}). Committing such a leg also emits
  `ExpirableFlowCommitted`, so that the feature's use can be counted.
- **Per source chain.** `append` accepts a version `0x02` leg only if the source chain enabled the
  `ExpirableTransfers` chain feature ({protocol-docs/interop-gating.md#chain-features}),
  `ManagerExpirableTransfersNotEnabled` otherwise. The destination needs no feature. A destination whose contracts
  don't support version `0x02` yet rejects the leg without changing any state; once it upgrades, the same finality
  proof still verifies (imported roots are never pruned), and the leg executes or expires as usual.
- **Nothing else reads the feature.** Executing, expiring and refunding a version `0x02` leg work whatever the
  feature says later, so disabling it never strands a leg already in flight.

## Expiry on the destination

`L2InteropHandler.expireAtomicBundle(bundle, finality, lowNullifierIndex)` is permissionless. It requires:

1. the bundle to be addressed to this chain and `Unreceived` or `Verified` (`BundleAlreadyProcessed`);
2. the flow's finality proof, checked exactly as for execution (`requireFlowFinalized`, including the receive
   filter), and a version `0x02` flow (`ManagerFlowNotExpirable`);
3. this chain's latest imported L1 interop root to be newer than `deadline + ATOMIC_FLOW_EXPIRY_DELAY`
   (`ManagerFlowNotExpiredYet`).

The finality proof ties the expiry to the flow that actually committed: without it, anyone could wrap the leg's
bundle hash in a made-up version `0x02` preimage with an earlier deadline and expire the leg under a `flowId` its
source never committed, leaving it neither executable nor refundable. So the proof is checked even when the bundle
is already `Verified`.

The handler marks the bundle `Expired` and emits `BundleExpired`. The `AtomicFlowManager` then inserts the leg's
expiry value into this chain's commitment tree and emits `FlowExpired`:

```
expiryValue = uint256(keccak256(abi.encode(ATOMIC_EXPIRY_LEAF_TAG, flowId, bundleHash)))
ATOMIC_EXPIRY_LEAF_TAG = bytes4(keccak256("AtomicInterop.expiry.v1"))
```

The tag keeps an expiry value from ever matching a commit value. The caller supplies the low-nullifier index,
as for a send (`zks_getImtLowNullifierIndex`).

Until someone expires the leg, it stays executable: expiry becoming possible doesn't stop execution. Both
outcomes are valid, and the destination's sequencer orders them.

### The delay

The deadline of a version `0x02` flow still bounds when its leg must settle on the source. Expiry waits another
`ATOMIC_FLOW_EXPIRY_DELAY` (1 day) of L1 time after it. Without the delay, a leg that settled just before the
deadline could be expired as soon as the destination imports a later root, so a sender could claw back a transfer
the recipient was able to execute. The delay is only that floor: the claim window a product wants is set by the
sender through `deadline`. Expiry takes nothing from the sender, so a short window only means that a transfer the
recipient doesn't execute goes back sooner.

## Refund on the source

`AtomicFlowManager.authorizeExpiryRefund(flow, bundle, expiry)` is permissionless. It requires:

1. a version `0x02` flow whose only leg is `bundle`, `Committed` on this chain (`ManagerLegNotCommitted`);
2. `expiry` to prove the leg's expiry value in the commitment tree of `bundle.destinationChainId`
   (`ProofSourceChainMismatch` otherwise), which this chain must accept
   ({protocol-docs/interop-gating.md#receive-filter}). The proof authenticates the tree root exactly like a
   finality proof ({protocol-docs/atomicity/proofs.md#finality}), without the deadline bound: the expiry always
   settles after the deadline.

The leg becomes `Revertable` and `FlowExpiryRefundAuthorized` is emitted. The existing `claimRefund` then pays
out with the same best-effort semantics as a timeout refund ({protocol-docs/atomicity/recovery.md}). If the
source token refuses the refund, for example because the sender is frozen too, the claim reverts and the leg
stays `Revertable`.

The expiry proof comes from the destination's RPC (`zks_getImtInclusionProof` with the expiry value and the
expiry block), exactly as a finality proof comes from the source's.

## Guarantee

A version `0x02` leg is either executed on the destination or refunded on the source, never both:

- On the destination, `bundleStatus` makes `FullyExecuted` and `Expired` mutually exclusive, and the handler is
  the only path to either.
- On the source, a refund requires the expiry value in the destination's tree. Only the destination's
  `AtomicFlowManager` inserts it, only from `expireAtomicBundle`, and only for a bundle addressed to that chain.
- The proof authenticates against an imported root, so it covers a batch already executed on L1, which can't be
  reverted. The receive filter keeps a disabled chain's prover from forging an expiry.

## Limits

- A halted or hostile destination can withhold the expiry, as it can withhold execution. So can a destination
  that never upgrades to contracts supporting version `0x02`: a sender should check the destination's protocol
  version before opting in.
- A bundle that was unbundled can't expire. Unbundling is the unbundler's own choice, by default the sender's.
- Multi-leg flows can't opt in.
