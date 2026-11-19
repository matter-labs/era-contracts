# Destination acceptance

An **accepted flow** (preimage version `ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED`, `0x02`) commits every leg on both
ends: the source commits it at send, and the destination **accepts** it into its own IMT. A flow finalizes only if
every commit and every acceptance is in time; otherwise the timeout refund
([recovery.md](./recovery.md)) returns the committed legs. That refund is the only one: no separate expiry
or retirement path is needed.

Source-only flows (`0x01`) keep the original rules and stay finalizable and refundable on every path.

## Why

A source-only flow can finalize without any destination receiving a bundle. A single-leg flow finalizes at
send, so its funds can stay locked if nobody relays the bundle, the destination halts or stops settling, the
operator refuses to take part, or the bundle fails a destination check such as chain registration, the receive
filter, or the base token check.

Accepted flows require proof of delivery by the deadline. A missing acceptance can authorize the existing timeout
refund for committed legs in either a single-leg or a multi-leg flow.

## Commitments

For `n` legs, `legChainIds` holds `2n` entries: the `n` source chains, then the `n` destination chains, both
aligned with `legBundleHashes`. Each entry names the tree that holds one **commitment**:

| Index   | Chain                 | IMT value                                                      |
| ------- | --------------------- | -------------------------------------------------------------- |
| `i`     | leg `i`'s source      | `commitValue = keccak256(ATOMIC_COMMIT_LEAF_TAG, flowId, h_i)` |
| `n + i` | leg `i`'s destination | `acceptValue = keccak256(ATOMIC_ACCEPT_LEAF_TAG, flowId, h_i)` |

- **Finality** (`requireFlowFinalized`) takes one inclusion proof per commitment, in this order, with the same
  in-time condition as before ([finality proofs](./proofs.md#finality)).
- **Timeout** (`authorizeRefund`) takes the index of one commitment proven absent past the deadline. The absence
  proof is bound to `legChainIds[index]`, exactly as for a missing commit
  ([timeout proofs](./proofs.md#timeout)).
- The [receive filter](../interop-gating.md#receive-filter) applies to these proofs. For a refund based on missing
  acceptance, the refunding source must allow the destination named in the absence proof.
- Soundness and completeness carry over unchanged: they hold per commitment, and the distinct leaf tags keep an
  acceptance from standing in for a commit.

## Accepting a leg

`L2InteropHandler.acceptAtomicBundle(bundle, preimage, lowNullifierIndex)` on the destination is permissionless. It
checks what execution would check on the bundle itself, then calls `AtomicFlowManager.accept`, which inserts the
accept value:

- the bundle is for this chain and its base token, and has not been verified or executed;
- the preimage is `0x02`, contains the bundle, and declares this chain as its destination;
- every chain of the flow is registered and passes this chain's receive filter
  ([receive filter](../interop-gating.md#receive-filter));
- the deadline has not verifiably passed, and the leg is not already accepted.

On the source, `append` checks that the leg's declared destination is the bundle's, so a wrong preimage fails at
send instead of producing a flow that can only time out.

The bundle's `executionAddress` restricts who can execute it. Anyone can accept it. Acceptance leaves the bundle
`Unreceived`; once the whole flow is proven, the bundle can be verified or executed.

## What acceptance proves

An acceptance receipt with an in-time inclusion proof shows that the destination had the bundle by the deadline
and passed the contract checks. This needs no new sequencer rules. Operators may refuse to include acceptance,
but the protocol does not depend on that choice. An L1-to-L2 priority transaction or a nested call can record the
same receipt as a direct transaction.

With the same legs and the required peers allowed, timely source commits and destination acceptances give `0x02`
the same execution and refund outcome as `0x01`. A missing acceptance gives `0x02` an additional basis for a timeout
refund. Whoever accepts the legs, acceptance cannot make a missing source commit count as present or take away a
refund that `0x01` would have allowed.

Acceptance does not guarantee the bundle's calls will succeed. A leg that reverts after the flow finalizes remains
the flow author's risk, as with `0x01`. Senders should simulate before sending. If a sender cannot read a private
destination chain, they can ask the recipient to check the incoming leg before sending. In a multi-leg flow,
each party can check its incoming leg before committing its own.

## Liveness

- **Halted destination.** The timeout's end branch proves absence against a chain's last batch
  ([timeout completeness](./proofs.md#completeness)), so a destination that stops settling before accepting
  cannot block the refund.
- **Deadline.** It must now cover relaying the bundle to the destination and the destination's settlement, as well
  as the source's. If nobody accepts a leg in time, the sender can use proof of its absence to claim a timeout refund.
- **No extra round.** Destinations can accept as soon as the bundle is sequenced on the source, in parallel with
  the other legs' commits.

## Retiring a format

Once a flow's deadline has passed, its outcome is fixed and each leg needs at most one more step, on one chain:

- **Timed out:** the leg is `Committed` on its source and refundable there (`authorizeRefund`, then `claimRefund`).
- **Finalized:** the leg is accepted on its destination, which holds the bundle (it is in the acceptance
  transaction) and the acceptance record. Only execution is left.

Both steps are permissionless, and each needs only the chain's own state plus commitments settled on L1. A chain can
therefore retire an accepted-flow format without the other chains' help:

1. Stop sending the format.
2. Wait until the last deadline of a flow in that format has passed and settled.
3. Sources refund their timed-out legs; destinations execute their pending accepted legs. Either can instead publish
   a claim root of what is left, which returns the value but does not run the leg's calls.
4. Remove the old paths.

A destination's claim must check that the flow finalized, or a leg could be paid out on the destination and also
refunded on its source. Legs restricted by `executionAddress` can only be executed by their executor. Deadlines are
not capped, so step 2 waits for the latest deadline any sender chose. Source-only flows (`0x01`) do not have this
property: a destination cannot list the legs addressed to it, and their bundles live only on the source.

## Cost

- One more IMT insert, with its L2->L1 log, per leg on the destination.
- Twice the inclusion proofs per execution (`2n`), still capped by `MAX_ATOMIC_FLOW_LEGS`.

## Rollout

A destination below this release cannot accept, so a `0x02` leg sent to it can only time out. SDKs and Prividium
keep sending `0x01` until every interop peer runs this release, then switch to `0x02`. Both versions stay accepted on
every path.
