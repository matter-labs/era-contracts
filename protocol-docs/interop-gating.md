# Interop gating

Interop is opt-in at two levels:

- Chains are **disabled** by default. Governance (the Bridgehub owner) enables a chain manually and one-way,
  normally only after the chain has permanently required its second proof system.
- A chain's admin chooses its interop peers on L1. Both chains of a pair must be enabled.

|                   | Disabled chain (default)                                                                                       | Enabled chain                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| L1 escrow         | capped once backfilled: the chain can withdraw only what was deposited into it ([cap](#per-chain-balance-cap)) | capped together: the enabled chains can withdraw only what was deposited into them ([pool](#interop-pool)) |
| Interop peers     | none can be whitelisted                                                                                        | enabled chains its admin whitelisted ([whitelist](#interop-peer-whitelist))                                |
| L1 asset handlers | the native token vault and the chain asset handler ([restriction](#asset-handler-restriction))                 | any                                                                                                        |

## Safety argument

Moving a chain's balance into the [interop pool](#interop-pool) at enabling already requires governance to trust the
chain's whole history, so forged interop state is covered by the same attestation. An enabled chain's broken prover
can lose the pool, but not the escrow of disabled chains. Before enabling, and once it is [backfilled](#backfill), a
disabled chain's broken prover can only lose funds deposited into that chain:

- the [cap](#per-chain-balance-cap) stops it from withdrawing more than was deposited into it;
- the [asset handler restriction](#asset-handler-restriction) keeps it away from L1 handlers that don't apply the cap;
- the [receive filter](#receive-filter) stops enabled chains from accepting its interop.

The [second proof system requirement](#second-proof-system-requirement) makes every batch of an enabled chain carry
both an Airbender and a ZiSK proof from then on, unless governance turns ZiSK off in an emergency. Governance may waive
the requirement for a chain it trusts for reasons checked offchain ([Enabling interop](#enabling-interop)).

## Second proof system requirement

`AdminFacet.permanentlyRequireSecondProofSystem()` is called by the chain admin on the chain's settlement layer. It
requires `getProofMode()` to be `ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE` (a multi-proof verifier with ZiSK enabled,
see {protocol-docs/multi-proof-verification.md}) and reverts with `NotMultiProofMode` otherwise. The requirement is
one-way (`SecondProofSystemAlreadyRequired`) and is read with `isSecondProofSystemRequired()`. Once it is set:

- **ZiSK-off is governance's.** `setProofSystemStatus(ProofSystem.Zisk, false)` is reserved for the Bridgehub owner,
  for emergencies such as a ZiSK bug. Turning ZiSK back on stays with the chain admin.
- **Upgrades keep the second proof system.** An upgrade that installs a verifier (`BaseZkSyncUpgrade._setVerifier`,
  used by every upgrade whose target release ships a new verifier, a same-minor verifier patch included) reverts with
  `NotMultiProofMode` unless the new verifier reports multi-proof mode with no proof system disabled. The `AdminFacet` checks the chain's verifier the same way
  after every diamond cut, so an upgrade that sets the verifier another way can't drop it either.

The requirement doesn't change which proofs the chain accepts. It only takes the way back to a single proof system
out of the chain admin's hands.

## Enabling interop

`L1MessageRoot.enableInterop(chainId, requireSecondProofSystem)` is callable only by the Bridgehub owner. It
requires the chain to be registered, no longer pending its [backfill](#backfill) (`ChainBalanceBackfillPending`), and
to have L1SLOAD on ({protocol-docs/l1sload.md#chain-config-flag}: `L1SloadNotEnabled`, or `ChainPredatesL1Sload` for
a chain still on pre-v36 facets).
It is one-way: there is no way to disable interop again (`InteropAlreadyEnabled`). `isInteropEnabled(chainId)` reads
the result.

With `requireSecondProofSystem`, the chain must also permanently require its second proof system
(`SecondProofSystemNotRequired`) and be in multi-proof mode right now, so not during an emergency ZiSK-off
(`NotMultiProofMode`). Governance enables without it only a chain it trusts for reasons checked offchain.

These checks are necessary, not sufficient: governance enables a chain only after the checks in
[Before enabling](#before-enabling).

## Per-chain balance cap

`L1NativeTokenVault` tracks, for every disabled chain and every asset not native to that chain, what passed through
the vault since the cap was introduced:

- `chainTotalDeposited[chainId][assetId]`: everything bridged to the chain, base-token deposits included.
- `chainTotalWithdrawn[chainId][assetId]`: everything released or minted on L1 for the chain's finalized
  withdrawals and claimed failed deposits.

A withdrawal or failed-deposit claim that would make `chainTotalWithdrawn` exceed
`chainTotalDeposited + chainBalanceBackfill` reverts with `ChainBalanceExceeded`, unless the chain is pending its
[backfill](#backfill): its balance from before the upgrade is not known yet, so its withdrawals are not capped, but they
still count in `chainTotalWithdrawn`. Once the chain is enabled, its flows count in the [interop pool](#interop-pool)
instead, and these counters stop.

- Assets native to the chain are not tracked. The chain mints them anyway, so a forged withdrawal of one only
  affects the holders of that chain's token.
- For L1-native assets, the global `bridgedOut` check ({protocol-docs/bridging.md#native-token-vault}) still applies
  first, to all chains.
- Only the vault applies the cap. Hence the [asset handler restriction](#asset-handler-restriction).

## Interop pool

Enabled chains share one balance per asset, because interop moves tokens between them without passing L1. The vault
keeps it in the same counters as a chain's, under `INTEROP_POOL_CHAIN_ID = uint256(keccak256("interop.pool")) - 1`,
which no chain can have: the Bridgehub caps chain IDs at `type(uint48).max` (`ChainIdTooBig`).

- `chainTotalDeposited[INTEROP_POOL_CHAIN_ID][assetId]`: everything bridged to enabled chains since they were
  enabled, plus the moved balances.
- `chainTotalWithdrawn[INTEROP_POOL_CHAIN_ID][assetId]`: everything released or minted on L1 for enabled chains since
  they were enabled.

A withdrawal or failed-deposit claim from an enabled chain that would make the pool's withdrawn total exceed its
deposited total reverts with `ChainBalanceExceeded`, which then carries the pool's totals. The pool has no backfill of
its own: the moved balances bring theirs.

- Assets native to an enabled chain, the withdrawing chain included, are not tracked: interop brings them to the
  other enabled chains without passing L1, so the pool can't bound them. An asset whose origin chain is enabled
  later stops being tracked from then on.
- A chain's balance from before it was enabled stays outside the pool until
  `moveChainBalanceToInteropPool(chainId, assetId)` adds it, `chainTotalDeposited + chainBalanceBackfill -
chainTotalWithdrawn`, to the pool's deposits. A negative balance, possible only for withdrawals made while the chain
  was pending its backfill, moves zero: the pool doesn't take on the chain's deficit. Anyone can call it, once per
  chain and asset (`ChainBalanceAlreadyInInteropPool`), after the chain is enabled and once it is no longer pending
  its [backfill](#backfill) (`ChainBalanceBackfillPending`).
- Until the move, the chain's withdrawals draw only on the pool and may revert, so the chain is backfilled before
  enabling and the balance is moved right after ([Order per chain](#order-per-chain)).

## Backfill

The counters start at zero when the cap is introduced, while chains already hold escrow. The upgrade that introduces
the cap marks every chain registered so far as pending its backfill (`chainBalanceBackfillPending`), from the vault's
`initializeUpgrade`, which only the proxy admin can call (`upgradeToAndCall`), once; chains registered later are
capped from creation. The vault owner (governance) supplies a pending chain's pre-upgrade balance as
`chainBalanceBackfill[chainId][assetId]` and then closes the chain's window:

- `setChainBalanceBackfill(chainId, assetIds, amounts)` sets the amounts, once per chain and asset
  (`ChainBalanceBackfillAlreadySet`; a zero amount leaves the asset settable). A chain's assets may take several
  calls. It refuses `INTEROP_POOL_CHAIN_ID` (`InvalidChainId`), which has no backfill.
- `markBackfilled(chainId)` ends the chain's pending state (`ChainBalanceBackfillNotPending` otherwise), which caps
  it in every asset from then on.

While a chain is pending, it is not capped ([cap](#per-chain-balance-cap)), it can't be
[enabled](#enabling-interop), and its balances can't move to the pool.
A backfill set on a chain that is not pending raises its cap at once, so governance can still add an asset it missed.
If the asset was already moved to the pool, the pool's deposits grow instead, by what the move would have added with
the backfill set: the chain's own counters no longer change once it is enabled.
The amounts are in [Backfill amounts](#backfill-amounts).

## Asset handler restriction

`L1AssetRouter` routes transfers to and from a disabled chain only to the native token vault and to the Bridgehub's
chain asset handler. Any other handler reverts with `AssetHandlerNotAllowed`. The check runs at all four entry points
(`bridgehubDepositBaseToken`, `bridgehubDeposit`, `finalizeDeposit`, `bridgeConfirmTransferResult`), and an asset
without a handler resolves to the vault.

A custom handler doesn't apply the cap, so without this check a disabled chain's broken prover could withdraw through
one what was deposited into other chains. As a side effect, a custom-handler deposit to a disabled chain can't be
withdrawn or claimed back while the chain stays disabled (see [Other limitations](#other-limitations)).

## Interop peer whitelist

`ChainRegistrationSender` keeps `interopPeerAllowed[chainId][peerChainId]` on L1, and chains read it there with
L1SLOAD ({protocol-docs/l1sload.md#interop-gating-through-l1-reads}). The chain's `InteropCenter` sends only to
peers that allowed it back and that it allowed (`DestinationChainNotAllowed`, {protocol-docs/interop.md}), and only
while neither chain is [suspended](./l1sload.md#suspending-a-chain).

- **`allowInteropPeer(chainId, peerChainId)`** is callable only by `chainId`'s admin. It sets the flag and the peer's
  [base token snapshot](./l1sload.md#the-base-token-snapshot).
  - Both chains must be registered and enabled (`InteropNotEnabled`). The peer can be neither the
    chain itself nor L1 (`InvalidInteropPeer`), and must have a batch in L1's message root
    ({protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}).
  - An allowed peer stays allowed (`InteropPeerAlreadyAllowed` on a second call) until `deregisterInteropPairs`
    removes it.
- **Consent is per side.** Each admin writes only its own chain's side. A chain accepts interop only from the peers
  on its own side ([receive filter](#receive-filter)), and sends only to peers that allowed it back, since sending
  reads both sides ({protocol-docs/l1sload.md#interop-gating-through-l1-reads}). So a one-sided whitelist starts no
  flow, but removing one side holds the flows already in flight ([K1](#k1-stuck-flows)).
- **Effect on L2.** A change reaches a chain once it imports an L1 anchor taken after it
  ({protocol-docs/l1sload.md#anchors}). Nothing is sent to L2, and `ChainRegistrationSender` is no longer a second
  bridge: it has no `bridgehubDeposit`, so a two-bridges request naming it reverts.
- **`registerChain`**, the retired consent-free registration, is removed.
- **`deregisterInteropPairs(chainRegisteredOn, chainsToDeregister)`** clears `interopPeerAllowed` for one chain's
  peers. It is callable by the owner and by that chain's admin (`Unauthorized` otherwise), and refuses a peer that
  settles on the chain (`InvalidInteropPeer`). Removing an allowed pair can strand the pair's unfinalized flows
  ([K1](#k1-stuck-flows)). Whoever removes a pair is responsible for them: an admin removing its chain's pair, for its
  users. The admin can allow the pair again.

## Receive filter

A source chain S is **allowed** for a chain C if S is C, or if C's `L2Bridgehub.isPeerAllowed(S)` holds: C allowed S
on L1 and neither chain is suspended, at C's anchor ({protocol-docs/l1sload.md#interop-gating-through-l1-reads}). C's
`AtomicFlowManager` reverts with `ManagerLegSourceChainNotAllowed` otherwise:

- **Finality** (`requireFlowFinalized`, {protocol-docs/atomicity/flow.md#3-finalize--requireflowfinalized}) needs
  every leg's source to be allowed.
- **Refunds** (`authorizeRefund`, {protocol-docs/atomicity/recovery.md#authorizerefund--claimrefund}) need the
  missing leg's source to be allowed.

The filter reads the whitelist when the bundle is verified, or executed if it wasn't verified first, not when it was
sent. A bundle from a peer that is removed or suspended stays unreceived, and executes once the admin allows the peer
again or governance resumes it; one verified before the removal still executes. `append` doesn't apply the filter: it only needs the other legs' sources
to be registered ({protocol-docs/atomicity/security.md#timeout-protocol-preconditions}).

The message root can't tell enabled chains apart: L1 aggregates every L1-settled chain's batch roots, so a disabled
chain's batches are as provable as any other. The filter has to cover refunds too. Otherwise a disabled chain's
broken prover could forge "present" toward one chain and "absent" toward another, so that one chain finalizes the
flow while another refunds it, and a leg is paid twice.

## Governance procedure

### Legacy registrations

The removed `registerChain` registered pairs without consent by writing `baseTokenAssetId` on the target chain's
`L2Bridgehub`. Since v36 no gating reads that entry ({protocol-docs/l1sload.md#interop-gating-through-l1-reads}), so
the legacy pairs are inert and need no cleanup.

### Backfill amounts

For each chain D and each asset not native to D, the backfill is the sum of two parts:

- **Pre-upgrade L1 flows:** deposits, minus finalized withdrawals, minus claimed failed deposits, up to the core
  upgrade transaction.
- **D's net interop:**
  - subtract every leg D appended;
  - credit the legs to D whose flow is final;
  - credit a timed-out leg only if it is in D's subtracted set;
  - count only evidence from roots that governance trusts.

D appends legs to legacy peers until its L2 upgrade, and to no one from then until it is enabled. So set D's
backfill only after D's upgrade. Otherwise the legs appended in between are never subtracted, and D's cap becomes
unbacked.

### Before enabling

Before `enableInterop(X)`:

- X's admin has turned L1SLOAD on (`enableInterop` refuses X until then, {protocol-docs/chain-config.md#l1sload});
- wait for X's second proof system requirement, unless governance waives it;
- check X's whole history:
  - the proof modes since the upgrade (no single-proven batches is recommended);
  - the interop X finalized or refunded while it was disabled;
- set X's backfill for every asset X holds, then mark X backfilled (`enableInterop` refuses X until then).

### Order per chain

1. Chain upgrade.
2. Governance sets the chain's backfill and marks it backfilled.
3. The admin turns ZiSK on and calls `permanentlyRequireSecondProofSystem`.
4. The admin turns L1SLOAD on (`setZKsyncOSL1SloadEnabled`).
5. Governance calls `enableInterop`.
6. Anyone calls `moveChainBalanceToInteropPool` for each asset the chain holds.
7. The admin calls `allowInteropPeer` for each peer.

## Known issues

### K1: stuck flows

A flow gets stuck when a chain's [receive filter](#receive-filter) refuses one of its legs' sources. With all legs
present, that chain can't finalize the flow; with a leg missing, a committed leg on that chain can't be refunded.
Causes:

- a one-sided whitelist, a removed pair, or a suspended chain;
- a leg from a chain that the destination doesn't whitelist;
- legacy flows that involve a chain that stays disabled.

SDKs should check both whitelists on L1 before sending.

### K2: undetermined backfill credits

A [backfill credit](#backfill-amounts) that depends on a chain that stays disabled may never be determined. Since the
backfill of an asset is set once, governance either includes it at its own risk or leaves it out, and then the
affected users can't withdraw it.

### Other limitations

- Enabled chains stay in the pool, even after an emergency ZiSK-off.
- Assets native to an enabled chain are not tracked by the pool ([interop pool](#interop-pool)).
- Pre-upgrade history is trusted.
- A chain registered before the upgrade is not capped until governance marks it backfilled, so governance does that
  soon after the chain's upgrade.
- The CTM, the upgrade contracts and the verifier code are trusted.
- Disabled chains' L2->L1 messages stay verifiable, so apps that accept them take on that chain's prover risk.
- Custom-handler deposits to disabled chains would be stranded ([restriction](#asset-handler-restriction)). There
  are none on mainnet.
