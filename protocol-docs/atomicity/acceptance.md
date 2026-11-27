# Destination acceptance

An **accepted flow** (preimage version `ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED`, `0x02`) needs every chain of the
flow to take part: each chain commits the legs it sends and **accepts** the legs it receives, with the bundle bytes,
and then inserts one **participation value** into its own IMT. A flow finalizes only if every chain's participation
is in time; otherwise the timeout refund ([recovery.md](./recovery.md)) returns the committed legs. That refund is
the only one: no separate expiry or retirement path is needed.

New flows are sent as `0x02` only. Source-only flows (`0x01`) sent before this release keep the original rules
and stay finalizable and refundable.

## Why

A source-only flow can finalize without any destination receiving a bundle. A single-leg flow finalizes at
send, so its funds can stay locked if nobody relays the bundle, the destination halts or stops settling, the
operator refuses to take part, or the bundle fails a destination check such as chain registration, the receive
filter, or the base token check.

Accepted flows require proof of delivery by the deadline. A missing participation can authorize the existing
timeout refund for committed legs in either a single-leg or a multi-leg flow.

Delivery is checked, not promised. Accepting a leg takes the full bundle, so the contract checks the exact bytes
against the flow and the bytes land in the destination's own chain history. After finality, executing a leg needs
nothing from its source chain. A participant confirmation without the bytes would rest on the destination's
off-chain service having stored them, and on a chain without such a service anyone could send it.

## Commitments

For `n` legs, `legChainIds` holds the `n` source chains and `legDestinationChainIds` the `n` destination chains,
both aligned with `legBundleHashes`. The **participating chains** are their distinct entries, in order of first
appearance, sources first. Each participating chain `c` inserts one value into its own IMT:

`participationValue = keccak256(ATOMIC_PARTICIPATION_LEAF_TAG, flowId, c)`

The chain inserts it in the transaction that completes its **local steps**: every leg the preimage declares from
`c` is committed (`append`), and every leg declared to `c` is accepted (`accept`). The steps can come in any order
and in separate transactions; only the last one inserts.

- **Finality** (`requireFlowFinalized`) takes one inclusion proof per participating chain, in that order, with the
  same in-time condition as before ([finality proofs](./proofs.md#finality)).
- **Timeout** (`authorizeRefund`) takes a leg index; the participation value of that leg's source or destination
  is proven absent past the deadline. The absence proof is bound to that chain, exactly as for a missing commit
  ([timeout proofs](./proofs.md#timeout)). A chain can also prove its own value absent, e.g. a swap chain that
  sent its leg but never accepted the incoming one.
- The [receive filter](../interop-gating.md#receive-filter) applies to these proofs. A refund needs the refunding
  chain to allow the chain named in the absence proof.
- Soundness and completeness carry over unchanged: they hold per commitment. The distinct leaf tag keeps a
  participation from standing in for a source-only commit, and the chain id in the value keeps one chain's
  participation from standing in for another's.

## Accepting a leg

`L2InteropHandler.acceptAtomicBundle(bundle, preimage, lowNullifierIndex)` on the destination is permissionless. It
checks what execution would check on the bundle itself, then calls `AtomicFlowManager.accept`, which records the
acceptance and inserts the chain's participation value if this was its last local step:

- the bundle is for this chain and its base token, its calls have the supported version and header, and it has
  not been verified or executed;
- the preimage is `0x02`, contains the bundle, declares this chain as its destination and the bundle's source as
  its source;
- every chain of the flow passes this chain's receive filter
  ([receive filter](../interop-gating.md#receive-filter));
- the deadline has not verifiably passed, and the leg is not already recorded.

On the source, `append` runs the same flow checks, receive filter included, and checks that the leg's declared
source is this chain and its declared destination is the bundle's, so a wrong preimage fails at send instead of
producing a flow that can only time out. `append` records the leg without a leaf of its own and inserts the chain's
participation value if this was its last local step.

`lowNullifierIndex` is used only by the call that inserts the participation value. Anyone can accept a leg, so
any of a chain's steps can turn out to be its last: callers pass the hint for the chain's participation value on
every step of an accepted flow. `0` always works, but walks the IMT's linked list from its start.

The bundle's `executionAddress` restricts who can execute it. Anyone can accept it. Acceptance leaves the bundle
`Unreceived`; once the whole flow is proven, the bundle can be verified or executed.

## What acceptance proves

A destination's participation with an in-time inclusion proof shows that it had every incoming bundle by the
deadline and that each passed the contract checks. This needs no new sequencer rules. Operators may refuse to include acceptance,
but the protocol does not depend on that choice. An L1-to-L2 priority transaction or a nested call can record the
same receipt as a direct transaction.

With the same legs and the required peers allowed, timely participation by every chain gives `0x02` the same
execution and refund outcome as `0x01`. A missing acceptance gives `0x02` an additional basis for a timeout refund.
Whoever accepts the legs, acceptance cannot make a missing source commit count as present or take away a refund
that `0x01` would have allowed.

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
  transaction) and the acceptance record (`legState` is `Accepted`). Only execution is left.

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

One IMT insert, with its L2->L1 log, per participating chain instead of per leg, and one inclusion proof per
participating chain at execution, capped at `2 * MAX_ATOMIC_FLOW_LEGS`:

| Flow                            | `0x01` leaves / proofs | `0x02` leaves / proofs |
| ------------------------------- | ---------------------- | ---------------------- |
| Single leg `A -> B`             | 1 / 1                  | 2 / 2                  |
| Swap `A <-> B`                  | 2 / 2                  | 2 / 2                  |
| `k` legs from `A` to `k` chains | `k` / `k`              | `k + 1` / `k + 1`      |

Each destination also sends one acceptance transaction per incoming leg, which carries the bundle bytes.

## Rollout

A chain on this release sends `0x02` only. A destination below this release cannot accept, so a `0x02` leg sent to
it can only time out: interop peers upgrade together. `0x01` flows sent before the upgrade stay finalizable and
refundable. Removing those paths in a later release needs every `0x01` leg refunded or executed first, and
destinations cannot list the `0x01` legs addressed to them ([retiring a format](#retiring-a-format)).
