# Destination acceptance

An **accepted flow** (preimage version `ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED`, `0x02`) commits every leg on both
ends: the source commits it at send, and the destination **accepts** it into its own IMT. A flow finalizes only if
every commit and every acceptance is in time; otherwise the timeout refund
({protocol-docs/atomicity/recovery.md}) returns the committed legs. That refund is the only one: no separate expiry
or retirement path is needed.

Source-only flows (`0x01`) keep the original rules and stay finalizable and refundable on every path.

## Why

A source-only flow binds only the senders. Nothing makes a destination take part, so a committed leg can stay
unexecuted forever: a leg whose call always reverts (frozen or de-KYC'd recipient, value sent to an address without
`receiveMessage`), or a leg the destination's operator refuses after commit. Single-leg flows commit at send, so
the timeout refund never applies to them, and refunding one leg of a multi-leg flow after its siblings executed
would break atomicity.

Acceptance moves the destination's decision before the deadline. A destination that does not accept in time makes
the flow time out, which the existing refund already handles for single-leg and multi-leg flows alike.

## Commitments

For `n` legs, `legChainIds` holds `2n` entries: the `n` source chains, then the `n` destination chains, both
aligned with `legBundleHashes`. Each entry names the tree that holds one **commitment**:

| Index   | Chain                 | IMT value                                                      |
| ------- | --------------------- | -------------------------------------------------------------- |
| `i`     | leg `i`'s source      | `commitValue = keccak256(ATOMIC_COMMIT_LEAF_TAG, flowId, h_i)` |
| `n + i` | leg `i`'s destination | `acceptValue = keccak256(ATOMIC_ACCEPT_LEAF_TAG, flowId, h_i)` |

- **Finality** (`requireFlowFinalized`) takes one inclusion proof per commitment, in this order, with the same
  in-time condition as before ({protocol-docs/atomicity/proofs.md#finality}).
- **Timeout** (`authorizeRefund`) takes the index of one commitment proven absent past the deadline. The absence
  proof is bound to `legChainIds[index]`, exactly as for a missing commit
  ({protocol-docs/atomicity/proofs.md#timeout}).
- Soundness and completeness carry over unchanged: they hold per commitment, and the distinct leaf tags keep an
  acceptance from standing in for a commit.

## Accepting a leg

`L2InteropHandler.acceptAtomicBundle(bundle, preimage, lowNullifierIndex)` on the destination is permissionless. It
checks what execution would check on the bundle itself, then calls `AtomicFlowManager.accept`, which inserts the
accept value:

- the bundle is for this chain and its base token, and has not been verified or executed;
- the preimage is `0x02`, contains the bundle, and declares this chain as its destination;
- every chain of the flow is registered and passes this chain's receive filter
  ({protocol-docs/interop-gating.md#receive-filter}), so the flow is one this chain could execute;
- the deadline has not verifiably passed, and the leg is not already accepted.

On the source, `append` checks that the leg's declared destination is the bundle's, so a wrong preimage fails at
send instead of producing a flow that can only time out.

The bundle's `executionAddress` restricts execution, not acceptance. Acceptance is the chain's decision, made by
what its operator includes. Accepting a leg does not execute it: the bundle stays `Unreceived`, and executes with
`executeAtomicBundle` once the whole flow is proven.

## What the destination's operator guarantees

Acceptance proves the destination has the bundle and that the contract-level checks passed. Whether the calls
still succeed at execution depends on state between acceptance and execution, which the contracts cannot pin. The
destination's operator is expected to make acceptance binding:

1. **Before accepting**, run the bundle's execution (for Prividium, through its policy engine) against current
   state. Accept only if it succeeds.
2. **Until the leg executes or the flow times out**, reject any transaction that would make an accepted bundle
   fail. This is a sequencer (server) rule, the prepare-then-commit pattern. It should not freeze touched state
   outright: one pending bundle would then block every transfer of a token whose shared state (`totalSupply`,
   balances of a pool) it touches.

Limits of this rule:

- It is a promise of the destination's sequencer. Proofs and contracts do not enforce it.
- It cannot cover calls whose outcome depends on block time or other state the sequencer does not control.
- A multi-leg flow whose accepted leg still fails at execution cannot be refunded without breaking atomicity. That
  remains the flow author's and the destination's risk, as in a source-only flow.

## Liveness

- **Halted destination.** The timeout's end branch proves absence against a chain's last batch
  ({protocol-docs/atomicity/proofs.md#completeness}), so a destination that stops settling before accepting
  cannot block the refund.
- **Deadline.** It must now cover relaying the bundle to the destination and the destination's settlement, as well
  as the source's. A leg nobody accepts in time is refunded to the sender instead of reaching the recipient.
- **No extra round.** Destinations can accept as soon as the bundle is sequenced on the source, in parallel with
  the other legs' commits.

## Cost

- One more IMT insert, with its L2->L1 log, per leg on the destination.
- Twice the inclusion proofs per execution (`2n`), still capped by `MAX_ATOMIC_FLOW_LEGS`.

## Rollout

A destination below this release cannot accept, so a `0x02` leg sent to it can only time out. SDKs and Prividium
keep sending `0x01` until every interop peer runs this release, then switch to `0x02`. Both versions stay accepted on
every path.
