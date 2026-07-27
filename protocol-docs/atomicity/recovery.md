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
depositor. There are two disjoint mechanisms, chosen per call by its local sender `InteropCall.from`:

- **Router-produced calls (`from == L2_ASSET_ROUTER_ADDR`).** These are the burns created by
  `initiateIndirectCall`. The manager asks the sender to reverse itself via
  `IAtomicRecoverable.recoverAtomicCall(destChainId, data)`, which returns a bool: `true` counts as a
  recovery, `false` (an unrecognized call) is skipped without reverting. The asset-router side of this
  hook — selector-pinned to `finalizeDeposit`, refunding the mint data's `originalCaller` through the
  NTV's failed-transfer path — is documented in {protocol-docs/bridging.md#atomic-recovery-hook}.
  Indirect calls force `interopCallValue == 0`, so router-produced calls never also carry native value.
- **Native base-token value on direct calls (`from != L2_ASSET_ROUTER_ADDR` and `value != 0`).** A
  direct call moves no asset-router funds, but it may carry base-token `value`. That value is reversed
  through `IAssetRouterShared.bridgehubRecoverBaseToken(destChainId, destBaseTokenAssetId, from, value)`,
  which reuses the same NTV failed-transfer recovery to re-credit the call's `from`. Every such leg
  counts as a recovery.

The manager is agnostic to call/encoding formats — it forwards `(destChainId, data)` and lets the
sender own its reversal; the L2 asset router is the only `IAtomicRecoverable` sender today, and the
`from == L2_ASSET_ROUTER_ADDR` test is what selects the hook. Implementations **must** gate both hooks
to the canonical `AtomicFlowManager` (`onlyAtomicFlowManager`) and **must** return `false` rather than
revert for calls they do not recognize, so one unrecognized call cannot brick the whole refund.

### Nothing recoverable → revert

If the walk recovers **nothing** (`recovered == 0`), `claimRefund` reverts with
`ManagerNoRecoverableCalls`. A bundle with no fund-moving leg has nothing to return, so a "refund" would
be a no-op; rejecting it keeps `Reverted` meaning "funds were actually returned."

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

- **Direct calls that moved no funds are skipped.** Their `from` (possibly an EOA) need not implement
  `IAtomicRecoverable`; there is nothing to reverse.
- **A refund succeeds as long as at least one call recovered** — not necessarily all of them.
- **Full refundability of an arbitrary bundle is not guaranteed.** Making a fund-moving leg recoverable
  (e.g. an asset-router deposit rather than a raw direct call) is the **flow author's responsibility**.
- **Indirect calls may not carry destination-side `interopCallValue`** (`IndirectCallCannotCarryValue`,
  rejected at send). Recovery refunds a call's `value` to its `InteropCall.from`, which for an indirect
  call is the sender contract (the asset router), not the payer — the funds would be stranded. Direct
  calls _may_ carry value; that is exactly the second mechanism above. See
  {protocol-docs/atomicity/security.md#non-guarantees}.
