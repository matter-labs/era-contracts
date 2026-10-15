# Interop gating

Interop between L1-settled chains is opt-in at two levels:

- Chains are **disabled** by default. Governance (the Bridgehub owner) enables a chain manually and one-way,
  and only after the chain has locked its second proof system.
- A chain's admin chooses its interop peers on L1. Both chains of a pair must be enabled.

|                   | Disabled chain (default)                                                                       | Enabled chain                                                               |
| ----------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| L1 escrow         | capped: the chain can withdraw only what was deposited into it ([cap](#per-chain-balance-cap)) | pooled with the other chains, uncapped                                      |
| Interop peers     | none can be whitelisted                                                                        | enabled chains its admin whitelisted ([whitelist](#interop-peer-whitelist)) |
| L1 asset handlers | the native token vault and the chain asset handler ([restriction](#asset-handler-restriction)) | any                                                                         |

## Safety argument

Lifting the cap at enabling already requires governance to trust the chain's whole history, so forged interop
state is covered by the same attestation. Before enabling, a disabled chain's broken prover can only lose funds
deposited into that chain:

- the [cap](#per-chain-balance-cap) stops it from withdrawing more than was deposited into it;
- the [asset handler restriction](#asset-handler-restriction) keeps it away from L1 handlers that don't apply the cap;
- the [receive filter](#receive-filter) stops enabled chains from accepting its interop.

The [second proof system lock](#second-proof-system-lock) makes every batch of an enabled chain carry both an
Airbender and a ZiSK proof from then on, unless governance turns ZiSK off in an emergency.

## Second proof system lock

`AdminFacet.lockSecondProofSystem()` is called by the chain admin on the chain's settlement layer. It requires
`getProofMode()` to be `ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE` (a multi-proof verifier with ZiSK enabled, see
{protocol-docs/multi-proof-verification.md}) and reverts with `NotMultiProofMode` otherwise. The lock is one-way
(`SecondProofSystemAlreadyLocked`) and is read with `isSecondProofSystemLocked()`. Once it is set:

- **ZiSK-off is governance's.** `setProofSystemStatus(ProofSystem.Zisk, false)` is reserved for the Bridgehub owner,
  for emergencies such as a ZiSK bug. Turning ZiSK back on stays with the chain admin.
- **Upgrades keep the second proof system.** An upgrade that installs a verifier (`BaseZkSyncUpgrade._setVerifier`,
  used by protocol upgrades and `upgradeVerifierOnly`) reverts with `NotMultiProofMode` unless the new verifier
  reports multi-proof mode with no proof system disabled.

The lock doesn't change which proofs the chain accepts. It only takes the way back to a single proof system out of
the chain admin's hands.

## Enabling interop

`L1MessageRoot.enableInterop(chainId)` is callable only by the Bridgehub owner. It requires the chain to be
registered, to settle on L1, to have locked its second proof system (`SecondProofSystemNotLocked`) and to be in
multi-proof mode right now, so not during an emergency ZiSK-off (`NotMultiProofMode`). It is one-way: there is no
way to disable interop again (`InteropAlreadyEnabled`). `isInteropEnabled(chainId)` reads the flag.

These checks are necessary, not sufficient: governance enables a chain only after the checks in
[Before enabling](#before-enabling).

## Per-chain balance cap

`L1NativeTokenVault` tracks, for every chain and every asset not native to that chain, what passed through the
vault since the cap was introduced:

- `chainTotalDeposited[chainId][assetId]`: everything bridged to the chain, base-token deposits included.
- `chainTotalWithdrawn[chainId][assetId]`: everything released or minted on L1 for the chain's finalized
  withdrawals and claimed failed deposits.

For a disabled chain, a withdrawal or failed-deposit claim that would make `chainTotalWithdrawn` exceed
`chainTotalDeposited + chainBalanceBackfill` reverts with `ChainBalanceExceeded`. Enabled chains are not capped,
and their counters keep counting.

- Assets native to the chain are not tracked. The chain mints them anyway, so a forged withdrawal of one only
  affects the holders of that chain's token.
- For L1-native assets, the global `bridgedOut` check ({protocol-docs/bridging.md#native-token-vault}) still applies
  first, to all chains.
- Only the vault applies the cap. Hence the [asset handler restriction](#asset-handler-restriction).

## Backfill

The counters start at zero when the cap is introduced, while chains already hold escrow. The vault owner
(governance) supplies each chain's pre-upgrade balance as `chainBalanceBackfill[chainId][assetId]`:

- `setChainBalanceBackfill(chainId, assetIds, amounts)` overwrites amounts, until
  `finalizeChainBalanceBackfill(chainId)`.
- After finalization, `increaseChainBalanceBackfill(chainId, assetIds, amounts)` can only add to them, for credits
  that are determined later ([K3](#k3-undetermined-backfill-credits)). A finalized backfill never decreases.

Until a chain's backfill is set, its users can only withdraw what was deposited after the upgrade. The amounts and
when to finalize them are in [Backfill amounts](#backfill-amounts).

## Asset handler restriction

`L1AssetRouter` routes transfers to and from a disabled chain only to the native token vault and to the Bridgehub's
chain asset handler. Any other handler reverts with `AssetHandlerNotAllowed`. The check runs at all four entry points
(`bridgehubDepositBaseToken`, `bridgehubDeposit`, `finalizeDeposit`, `bridgeConfirmTransferResult`), and an asset
without a handler resolves to the vault.

A custom handler doesn't apply the cap, so without this check a disabled chain's broken prover could withdraw through
one what was deposited into other chains. As a side effect, a custom-handler deposit to a disabled chain can't be
withdrawn or claimed back while the chain stays disabled (see [Other limitations](#other-limitations)).

## Interop peer whitelist

`ChainRegistrationSender` keeps `interopPeerAllowed[chainId][peerChainId]` and mirrors it into each chain's
`L2Bridgehub` (`baseTokenAssetId(peerChainId)`), which lets the chain send interop to the peer
({protocol-docs/interop.md}).

- **`setInteropPeer(chainId, peerChainId, allowed)`** is callable only by `chainId`'s admin. It stores the flag and
  sends an L2 service transaction to `chainId`'s `L2Bridgehub`: it registers the peer when allowed and clears the
  peer's entry when revoked.
  - Both chains must be registered and settle on L1. The peer can be neither the chain itself nor L1
    (`InvalidInteropPeer`).
  - Allowing also requires both chains to be enabled (`InteropNotEnabled`) and the peer to have a batch in L1's
    message root ({protocol-docs/chain-lifecycle.md#interop-registration-chainregistrationsender}). Revoking
    requires neither.
- **Consent is per side.** Each admin writes only its own chain's side, and a chain accepts interop only from
  peers on its own side ([receive filter](#receive-filter)). Two-way interop needs both admins, and a one-sided
  whitelist can strand flows ([K1](#k1-stuck-flows)). SDKs should check both sides on L1 before sending.
- **`bridgehubDeposit`** (Bridgehub two-bridges path, encoding version `0x02`, data `abi.encode(peerChainId)`)
  re-sends a pair's current state: the registration if allowed, the clearing otherwise. Anyone can call it, and
  the caller pays the L1->L2 transaction in the base token.
- **`registerChain`**, the retired consent-free registration, reverts with `RegistrationRequiresConsent`. Its paid
  counterpart, deposit encoding version `0x01`, reverts with `UnsupportedEncodingVersion`. Governance clears the
  pairs they registered ([Legacy registrations](#legacy-registrations)).
- **`deregisterLegacyPairs(chainsRegisteredOn, chainsToDeregister)`** is owner-only. It sends the clearing service
  transactions and leaves `interopPeerAllowed` untouched.

## Receive filter

Contracts don't enforce this rule yet. For now, the enabled chain's operator enforces it through node
configuration, which includes force-failing L1->L2 transactions that break it. A later L2 release moves it into
`AtomicFlowManager`. Until then, see [K2](#k2-operator-trust-until-the-on-chain-filter-ships).

A source chain S is **allowed** for a chain C if S is C, or if both of these hold:

- `interopPeerAllowed[C][S]` holds on L1;
- C's `L2Bridgehub.baseTokenAssetId(S)` is non-zero.

Then:

- **Finality** (`requireFlowFinalized`, {protocol-docs/atomicity/flow.md#3-finalize--requireflowfinalized}) needs
  every leg's source to be allowed.
- **Refunds** (`authorizeRefund`, {protocol-docs/atomicity/recovery.md#authorizerefund--claimrefund}) need the
  missing leg's source to be allowed.

The message root can't tell enabled chains apart: L1 aggregates every L1-settled chain's batch roots, so a disabled
chain's batches are as provable as any other. The filter has to cover refunds too. Otherwise a disabled chain's
broken prover could forge "present" toward one chain and "absent" toward another, so that one chain finalizes the
flow while another refunds it, and a leg is paid twice.

## Governance procedure

### Legacy registrations

The retired `registerChain` registered pairs without consent. Clear them with `deregisterLegacyPairs` in the first
governance transaction after the core upgrade. To find them:

1. list the L1 priority transactions that call the `registerChainForInterop` selector;
2. cross-check each pair against `baseTokenAssetId` on the target chain's `L2Bridgehub`.

### Backfill amounts

For each chain D and each asset not native to D, the backfill is the sum of two parts:

- **Pre-upgrade L1 flows:** deposits, minus finalized withdrawals, minus claimed failed deposits, up to the core
  upgrade transaction.
- **D's net interop:**
  - subtract every leg D appended;
  - credit the legs to D whose flow is final;
  - credit a timed-out leg only if it is in D's subtracted set;
  - count only evidence from roots that governance trusts.

Finalize D's backfill only after D's legacy clearing is confirmed on D's L2. Otherwise D can still append legs that
are never subtracted, and its cap becomes unbacked.

### Before enabling

Before `enableInterop(X)`:

- wait for X's second proof system lock;
- check X's whole history:
  - the proof modes since the upgrade (no single-proven batches is recommended);
  - the interop X finalized or refunded while it was disabled;
- confirm that every legacy registration on X's L2 is cleared;
- trust X's operator to run the [receive filter](#receive-filter).

### Order per chain

1. Chain upgrade.
2. Backfill, then finalize it.
3. The admin turns ZiSK on and calls `lockSecondProofSystem`.
4. Governance calls `enableInterop`.
5. The admin calls `setInteropPeer` for each peer.

## Known issues

### K1: stuck flows

A flow whose legs are all present but which some chain refuses can neither finalize nor be refunded. Causes:

- a one-sided whitelist;
- a leg from a chain that the destination doesn't whitelist;
- a revocation that lands while the flow is in flight;
- legacy flows that involve a chain that stays disabled.

SDKs should check both whitelists on L1 before sending.

### K2: operator trust until the on-chain filter ships

An enabled chain's operator that doesn't run the [receive filter](#receive-filter) can pay forged legs out of the
pool. The same holds while the chain is in permanent priority mode.

### K3: undetermined backfill credits

A [backfill credit](#backfill-amounts) that depends on a chain that stays disabled may never be determined. The
affected users can't withdraw it unless governance credits it at its own risk (`increaseChainBalanceBackfill`).

### Other limitations

- Enabled chains stay uncapped, even after an emergency ZiSK-off.
- Pre-upgrade history is trusted.
- The CTM, the upgrade contracts and the verifier code are trusted.
- Disabled chains' L2->L1 messages stay verifiable, so apps that accept them take on that chain's prover risk.
- Custom-handler deposits to disabled chains would be stranded ([restriction](#asset-handler-restriction)). There
  are none on mainnet.
