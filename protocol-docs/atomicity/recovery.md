# Timeout and refund

When a flow misses its deadline, the atomic protocol unwinds the legs that _did_ commit. This is a
two-call, permissionless sequence on each committed leg's source chain, driven by the
`AtomicFlowManager`, and it is **best-effort by design** — see [Non-guarantees](#non-guarantees).

The proof that authorizes the unwind — that a leg is genuinely absent past the deadline and the flow can
never finalize — is specified in {protocol-docs/atomicity/proofs.md#timeout}. This page covers what
happens _after_ the proof checks out.

## `authorizeRefund` → `claimRefund`

1. **`authorizeRefund(flow, missingLegIndex, absence)`** — verifies one timeout absence proof for the
   missing leg (bound to that leg's declared source chain), then flips **this chain's** `Committed` legs
   of the flow to `Revertable`, emitting `FlowRefundAuthorized` for each. Legs committed on other chains
   are not in this manager's state and are simply skipped; each chain authorizes its own legs from the
   same absence proof. One proof of _one_ missing leg is enough to unwind the whole flow, because a flow
   that cannot finalize cannot finalize anywhere.
2. **`claimRefund(flowId, bundle)`** — requires the leg to be `Revertable`, flips it to `Reverted`
   **before** any external call (CEI — a reentrant claim hits the state check), then calls
   `_recoverBundle`, emitting `FlowRefunded`. The manager holds no funds, so it needs no reentrancy
   guard.

`claimRefund` takes the full `bundle` bytes (not just the hash) because it must re-derive each call's
sender and value to drive recovery; the hash is recomputed and matched against the `Revertable` entry.

## `_recoverBundle`: reversing the burns

`_recoverBundle` walks the bundle's calls and reverses each recoverable one, re-crediting the original
depositor. There are two disjoint mechanisms, selected per call by testing its local sender
`InteropCall.from` against the asset-router address:

- **Router-produced calls (`from == L2_ASSET_ROUTER_ADDR`).** These are the burns created by
  `initiateIndirectCall`. The manager asks the sender to reverse itself via
  `IAtomicRecoverable.recoverAtomicCall(destChainId, data)`, which returns a bool: `true` means the
  burn was reversed, `false` (an unrecognized call) is skipped without reverting. The asset-router side
  of this hook — selector-pinned to `finalizeDeposit`, refunding the mint data's `originalCaller`
  through the failed-transfer path of the asset handler registered for the asset — is documented in
  {protocol-docs/bridging.md#atomic-recovery-hook}.
  Indirect calls force `interopCallValue == 0`, so router-produced calls never also carry native value.
- **Native base-token value on non-router calls (`from != L2_ASSET_ROUTER_ADDR` and `value != 0`).**
  Only a direct call can carry base-token `value` (indirect calls force it to zero), and a direct call
  moves no asset-router funds. That value is reversed
  through `IAssetRouterShared.bridgehubRecoverBaseToken(destChainId, destBaseTokenAssetId, from, value)`,
  which reuses the same NTV failed-transfer recovery to re-credit the call's `from`.

The manager is agnostic to call/encoding formats — it forwards `(destChainId, data)` and lets the
sender own its reversal — but the dispatch itself is **address-pinned, not sender-agnostic**: the L2
asset router is the only `IAtomicRecoverable` sender the manager ever invokes. A burn produced by any
other `IL2CrossChainSender` indirect starter matches neither mechanism and is not recovered — an
accepted limitation, see
{protocol-docs/atomicity/security.md#known-issues-and-accepted-limitations}. Implementations **must**
gate both hooks to the canonical `AtomicFlowManager` (`onlyAtomicFlowManager`) and **must** return
`false` rather than revert for calls they do not recognize.

### The walk is all-or-nothing, not per-call isolated

`_recoverBundle` invokes `recoverAtomicCall` / `bridgehubRecoverBaseToken` as **plain external calls**
with no failure containment (the codebase forbids `try`/`catch`). So a revert in _any_ attempted
recovery propagates and rolls back the whole `claimRefund` transaction — including recoveries that
already succeeded earlier in the loop, and the `Revertable -> Reverted` state change. The leg stays
`Revertable` and the claim can be retried, but it cannot be partially applied.

Returning `false` is therefore the _only_ way a sender can decline a call without taking the whole
refund down with it. "Best-effort" means exactly that — unrecognized calls are skipped — and nothing
more: it does **not** isolate a reverting recovery from the rest of the bundle.

### Nothing recoverable → no-op claim

A bundle where no call is recoverable has nothing the manager can return (which does not imply no
funds were burned — a non-router indirect starter's burn is skipped, see above): the claim then simply
flips the leg to `Reverted` without moving anything. The state transition (releasing the leg from the flow) is
meaningful on its own and is deliberately not blocked, so `Reverted` means "the refund was claimed",
not necessarily "funds were returned".

Putting it together: a claim succeeds iff **no** attempted recovery reverts — including when nothing
was recoverable at all.

### L1 destinations are asserted out

`_recoverBundle` asserts `destChainId != L1_CHAIN_ID` (`RecoverToL1NotSupported`), as do
`L2AssetRouter.recoverAtomicCall`, `L2AssetRouter.bridgehubRecoverBaseToken` and, at the accounting
layer itself, `L2AssetTracker.handleRecoverBaseTokenBridgingOnL2`. Atomic L2->L1 bundles are already
rejected at send time (`AtomicBundleToL1NotSupported`), so this is belt-and-suspenders — but a
load-bearing one: it keeps recovery from ever reaching the append-only L1 deposit/withdrawal counters
in `L2AssetTracker`, whose settlement-layer-conditional updates are only correct when evaluated at
send time, not recovery time. The full accounting reason is in
{protocol-docs/bridging.md#security-notes} ("L2 -> L1 withdrawals are never revertable").

## Non-guarantees

Recovery is best-effort, and the protocol is explicit about what it does **not** promise:

- **Non-router calls get no reversal hook.** A direct call's `from` (possibly an EOA) need not
  implement `IAtomicRecoverable` and moved no funds — there is nothing to reverse. A non-router
  indirect starter's burn, however, is skipped even though there _was_ something to reverse (see
  {protocol-docs/atomicity/security.md#known-issues-and-accepted-limitations}).
- **A claim needs zero reverts.** No attempted recovery may revert — a single reverting call rolls the
  whole claim back (see [above](#the-walk-is-all-or-nothing-not-per-call-isolated)). Not every call has
  to recover (a claim that recovers nothing still consumes the leg), but every call that is _attempted_
  has to not throw.
- **Full refundability of an arbitrary bundle is not guaranteed**, and neither is eventual
  recoverability: a bundle containing a call whose recovery reverts deterministically (malformed
  recognized calldata, or a downstream NTV failure) can leave the leg permanently stuck at `Revertable`,
  since every retry hits the same revert. Making a fund-moving leg recoverable — and its recovery
  robust — is the **flow author's responsibility**.
- **Indirect calls may not carry destination-side `interopCallValue`** (`IndirectCallCannotCarryValue`,
  rejected at send). Recovery refunds a call's `value` to its `InteropCall.from`, which for an indirect
  call is the starter contract (the asset router for router-produced calls), not the payer — the funds
  would be stranded. Direct
  calls _may_ carry value; that is exactly the second mechanism above. See
  {protocol-docs/atomicity/security.md#non-guarantees}.
