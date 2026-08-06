# Bridging

This document is the single source of truth for the protocol-level behavior of the bridge contracts
(`l1-contracts/contracts/bridge/`). Contract doc comments reference this file instead of repeating the
narrative. For the atomic interop flow itself, see {protocol-docs/atomicity/README.md}.

## Contract map

| Contract                                                                                          | Chain                      | Role                                                                                                                                                         |
| ------------------------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `AssetRouterBase` / `L1AssetRouter` / `L2AssetRouter`                                             | L1 + every ZK chain        | Routes asset transfers (L1 <-> ZK chain bridging and L2 <-> L2 interop) to per-asset handlers.                                                               |
| `NativeTokenVaultBase` / `L1NativeTokenVault` / `L2NativeTokenVault` (+ `L2NativeTokenVaultZKOS`) | L1 + every ZK chain        | The default asset handler for ETH and ERC20 tokens: escrows native tokens, mints/burns bridged representations.                                              |
| `L1Nullifier`                                                                                     | L1                         | Tracks initiated L1 -> L2 deposits (`depositHappened`) and verifies/clears them when a failed deposit is claimed back on L1.                                 |
| `BaseTokenHolder` (`l2-system/`)                                                                  | every ZK chain             | Escrow of the chain's base-token reserves; replaces mint/burn with transfers for EVM compatibility.                                                          |
| `BridgedStandardERC20`                                                                            | ZK chains (beacon-proxied) | The standard bridged-token implementation, deployed per token behind the NTV's beacon.                                                                       |
| `L2WrappedBaseToken`                                                                              | ZK chains                  | The canonical wrapped-base-token (WETH-style) implementation. An `ERC20PermitUpgradeable`, deployed behind its own proxy — **not** the bridged-token beacon. |

The `L2AssetRouter`, `L2NativeTokenVault`, `BaseTokenHolder`, interop center/handler and
atomic-flow manager are genesis-deployed built-ins at fixed, identical addresses on every ZK chain
(`L2ContractAddresses.sol`). L2 contracts must not have constructors or immutables (ZKsync OS
compatibility); they are initialized via `initL2`/`updateL2` called by the complex upgrader, and
several "immutable-looking" CAPSLOCK names (`L1_CHAIN_ID`, `BASE_TOKEN_ASSET_ID`, ...) are plain storage
variables kept capitalized for backward compatibility with older versions where they were immutables.

## Asset IDs, asset handlers, deployment trackers

- **Asset ID**: `keccak256(abi.encode(originChainId, assetDeploymentTracker, assetRegistrationData))`
  (`DataEncoding.encodeAssetId`). For NTV-managed tokens the deployment tracker is the L2 NTV address and
  the registration data is the token address (`DataEncoding.encodeNTVAssetId`).
- **Asset handler** (`assetHandlerAddress` mapping in the asset router): the contract where bridged funds
  are locked/minted for a given asset ID. Current handlers: the NTV for tokens, the Bridgehub for chains.
  (Liquidity used to be locked directly in the SharedBridge.)
- **Asset deployment tracker** (`assetDeploymentTracker` mapping, L1 only): the contract that is allowed to
  set asset handlers for its assets on L2 chains. Current trackers: the NTV for tokens, the
  `CTMDeploymentTracker` for chains; custom tokens may have their own.

Registration flows:

- `setAssetHandlerAddressThisChain` — sets the handler locally. The caller is encoded into the asset ID, so
  only the NTV or the asset's registered deployment tracker may call it.
- `L1AssetRouter.bridgehubDeposit` with encoding version `0x02`
  (`SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION`) — sets the handler for an asset on a remote ZK chain via
  an L1 -> L2 transaction; the deployment tracker's `bridgeCheckCounterpartAddress` validates the counterpart
  address (the L1 NTV only accepts `L2_NATIVE_TOKEN_VAULT_ADDR`). The L2 side (`L2AssetRouter.setAssetHandlerAddress`)
  only accepts this from the aliased L1 asset router.
- If a burn is requested for an asset with no handler, the router calls
  `INativeTokenVaultBase.tryRegisterTokenFromBurnData` as a UX feature: the NTV registers the token on the
  fly if it is native to the chain, and is trusted to revert otherwise. Token registration in the NTV is
  deliberately permissionless (`registerToken`, `ensureTokenIsRegistered`) so bridging native tokens never
  needs an allowlist.

## Asset routing: burn / mint

All transfers follow one pattern: the source-side asset handler's `bridgeBurn` locks or burns the funds and
returns `bridgeMintData`; the destination-side handler's `bridgeMint` consumes that data to unlock or mint.

### Deposit initiation (source side)

- `bridgehubDeposit` (L1, called only by the Bridgehub via `requestL2TransactionTwoBridges`) or
  `initiateIndirectCall` (L2, called only by the `InteropCenter`) decode the user data. Only encoding
  version `0x01` (`NEW_ENCODING_VERSION`) is supported for asset transfers; depositing the destination
  chain's base token through this path is rejected (`AssetIdNotSupported`).
- The router calls `bridgeBurn` on the handler and builds the destination calldata:
  `finalizeDeposit(block.chainid, assetId, bridgeMintData)`.
- On L1 the deposit is identified by `txDataHash = keccak256(0x01 || abi.encode(originalCaller, assetId, transferData))`
  (`DataEncoding.encodeTxDataHash`); the `0x01` prefix is collision-resistant with the removed legacy
  format, whose first encoded word was an address with zero upper bytes. The Bridgehub confirms the L1 -> L2
  transaction hash via `bridgehubConfirmL2Transaction`, which the router forwards to
  `L1Nullifier.bridgehubConfirmL2TransactionForwarded`; the nullifier records
  `depositHappened[chainId][l2TxHash] = txDataHash` (rejecting duplicates).
- For L2 -> L2 the `InteropCallStarter` targets the L2 asset router (same address on every ZK chain); for an
  L2 -> L1 withdrawal it targets the known `L1_ASSET_ROUTER` address instead — the `finalizeDeposit`
  calldata is identical. The bridged amount travels inside that calldata, not as call value: the returned
  starter merely echoes the requested `interopCallValue` (always zero for an indirect call) so the
  InteropCenter's `IndirectCallValueMismatch` check passes.
- `bridgehubDepositBaseToken` lets the Bridgehub (L1; or the Era diamond proxy for `ERA_CHAIN_ID`) /
  `InteropCenter` (L2) acquire the destination chain's `mintValue`: it burns the base token through the
  handler but records nothing, because a failed transaction refunds the base token to the L2
  `refundRecipient` rather than being claimable on L1.

### Finalization (destination side)

`finalizeDeposit(sourceChainId, assetId, transferData)` is the new-format finalization entry point. It
is not the only one: `L1AssetRouter.finalizeWithdrawal` is still live and forwards to
`L1Nullifier.finalizeWithdrawal`, which serves the legacy withdrawal-message format (see
[Legacy compatibility](#legacy-compatibility)). It looks up the asset
handler and calls `bridgeMint`; if no handler is registered yet, it registers the NTV as the handler and
mints through it (`msg.value` is forwarded so ETH cannot get stuck in the router; whether non-zero value is
supported is decided at the handler layer). `_sourceChainId` is the source chain of the _message_, not
necessarily the origin chain of the token; since chains can be malicious and supply arbitrary transfer
data, any data that affects chains other than the source chain must be validated with special care.

Authorization:

- Cross-chain messages reach `finalizeDeposit` only through `receiveMessage` (ERC-7786), called by the
  chain's interop handler (`L2InteropHandler` system contract on L2, configured `l1InteropHandler` on L1)
  while executing an interop bundle. `receiveMessage` re-invokes the payload via a self-call and enforces:
  - the ERC-7930 sender is the asset-router counterpart on the source chain
    (`_isValidInteropSender`): on L1, any non-L1 chain with sender `L2_ASSET_ROUTER_ADDR`; on L2, any
    non-L1 chain with sender equal to this router's own address (identical on all ZK chains; interop is
    only initiated on L2s, never on L1);
  - the payload selector is exactly `finalizeDeposit` and the payload is long enough;
  - the message sender's chain ID equals the payload's `_sourceChainId`. Under the honest-proof trust
    model these are always equal, but the check guarantees a payload can never finalize a deposit under a
    chain ID other than the one whose message inclusion was proven — asset accounting depends on this.
  - Reverts of the inner call are bubbled up verbatim so callers can react to specific errors (e.g. the
    TBM flow retries withdrawals on `InsufficientChainBalance`).
- On L2, `finalizeDeposit` is additionally callable by the aliased L1 asset router (L1 -> L2 deposits) and
  rejects the chain's own base-token asset ID. On L1 it is `onlySelfOrNullifier`: the router itself, or
  `L1Nullifier` finalizing a legacy-format withdrawal.
- Replay protection depends on the path. A new-format bundle executes at most once via the interop
  handler's `bundleStatus` mapping. The legacy `finalizeWithdrawal` path is guarded by
  `L1Nullifier.isWithdrawalFinalized[chainId][batch][messageIndex]` — actively written and checked
  (`WithdrawalAlreadyFinalized`), not deprecated — and it additionally consults the legacy bridge's own
  `isWithdrawalFinalized` for pre-migration withdrawals.

## Native Token Vault

The NTV is the asset handler for "standard" tokens. It does not support custom token logic (e.g. rebase
tokens) and rejects fee-on-transfer tokens (`TokensWithFeesNotSupported`).

- `originChainId` / `tokenAddress` / `assetId` mappings are always populated atomically. A token is
  **native** if `originChainId[assetId] == block.chainid`, otherwise **bridged**.
- `bridgeBurn`: for a native token, escrows it in the vault (`safeTransferFrom`); for a bridged token,
  burns it via `IBridgedStandardToken.bridgeBurn`. Zero amounts are rejected. It returns
  `bridgeMintData = (originalCaller, remoteReceiver, originToken, amount, erc20Metadata)`. Bridging
  a natively-registered WETH is forbidden (`BurningNativeWETHNotSupported`); WETH can only be registered in
  the _L1_ NTV, so all WETH-related operations are restricted to L1 deposits to keep future logic upgrades easy.
- `bridgeMint`: for a bridged token, mints it, deploying the token contract on first bridging; for a native
  token, releases escrowed funds (`_withdrawFunds`; on L1 the ETH base token is sent with a raw call, ERC20s
  with `safeTransfer`). Chain-balance bookkeeping is decreased **before** funds are handed out so that a
  malicious token or ETH recipient cannot overwrite the transient values from `L1Nullifier`.
  The mint amount's correctness is guaranteed by the ZK proofs of the sending chain (plus 2FA on ZKsync OS
  chains); there is no on-chain per-chain balance enforcement. Token _metadata_ in the mint data is not
  verified — a known issue affecting UX only, never loss of funds, acceptable while chain type managers are
  decently trusted.
- Bridged tokens are `BridgedStandardERC20` beacon proxies deployed via CREATE2 at a deterministic address
  (`calculateCreate2TokenAddress`); the deployed address is checked against the expectation. The salt is
  `keccak256(abi.encode(originChainId, originToken))`, except on L2 for L1-origin tokens where it is the
  plain L1 token address (legacy compatibility). On L2 the deployment goes through the `ContractDeployer`
  system contract with the pinned `L2_TOKEN_PROXY_BYTECODE_HASH`; `L2NativeTokenVaultZKOS` uses plain
  CREATE2 (zkOS-first chains have no legacy shared bridge, so the NTV is the sole deployer of bridged
  tokens) and must hold no storage of its own.
- **L1 accounting**: `L1NativeTokenVault.bridgedOut[assetId]` is the net amount of each L1-native token
  currently bridged out of L1. It increases on outbound flows and decreases on inbound ones, so unlike raw
  `balanceOf` it cannot be skewed by direct transfers into the vault, and it is bounded by the actually
  escrowed amount. An inbound amount exceeding `bridgedOut` is only possible if bridged representations
  were forged upstream, so `_handleBridgeFromChain` reverts with `InsufficientChainBalance` instead of
  recording it. The old per-chain `chainBalance` accounting is deprecated (`DEPRECATED_chainBalance`); the
  `chainBalance(chainId, assetId)` getter remains for backwards compatibility and will revert in the next release.
- **Pausability**: inherited by both vaults from the base. On L1 it is part of the emergency controls; on
  L2 it exists only for shared-code reasons and should not be used as an emergency mechanism — future L2
  logic should rely on the L1/Gateway freeze flow.

### Populating `bridgedOut` during an in-place upgrade

A vault that is upgraded in place starts with `bridgedOut == 0` while still holding all of the escrow that
was bridged out before the upgrade. Every withdrawal of an L1-native asset would therefore look like an
inbound amount exceeding the outstanding one and be rejected as forged. `populateBridgedOut(assetIds)` folds
the pre-upgrade accounting into `bridgedOut`, once per asset, and `stage3` of the upgrade runs it for the
L1-native assets in the vault's `bridgedTokens` enumeration that have a non-zero pre-upgrade amount, batched
across transactions (see `l1-contracts/deploy-scripts/upgrade/default-upgrade/BridgedOutPopulationLib.sol`;
assets whose
amount is zero are left out of the batches entirely, so their `bridgedOutPopulated` flag stays unset — there
is nothing to fold in for them, now or later).

- For an asset the removed v31 `L1AssetTracker` registered, the amount is the complement of **L1's own
  bulkhead** there: L1 is the origin chain of these assets, so its bulkhead starts at `MAX_TOKEN_BALANCE`
  and moves by exactly the amount of every outflow from and inflow to L1. Reading that instead of summing
  the tracker's per-chain entries makes the result immune to amounts being moved between chains, which the
  tracker's own migration entry points can still do after the upgrade. The tracker is located through the
  vault's retained `__DEPRECATED_l1AssetTracker` slot.
- Otherwise — for an asset that never went through the tracker migration — the amount is the sum of the
  vault's own `DEPRECATED_chainBalance` entries over the chains the bridgehub reports. The chain list is read
  by the vault itself rather than supplied by the caller, so the caller cannot undercount it; the sum is exact
  as long as the bridgehub still lists every chain that holds a non-zero entry, which holds because chains are
  never removed from it.
  On an ecosystem deployed after the trackers were removed both sources are empty and the population is a
  no-op.
- No privileges are required. Neither source can be influenced by the caller, and an asset can only be
  folded in once. Amounts bridged in the window between the upgrade and the population are preserved, since
  the population only ever adds to `bridgedOut`.
- Until an asset is populated, only its pre-upgrade escrow is unwithdrawable — amounts bridged out after the
  upgrade raise `bridgedOut` normally and can be withdrawn against. Legacy tokens that predate the
  `bridgedTokens` enumeration have to be backfilled into it before they can be populated at all, which is why
  `stage3` registers them first.

## Base-token handling

- The chain's base token is escrowed off-vault in `BaseTokenHolder`, initialized with `2^127 - 1` base
  tokens; transfers from the holder replace minting (better EVM/Foundry compatibility). `give` (interop
  handler only) pays out inbound value; `burnAndStartBridging` (InteropCenter or NTV) receives outbound
  value; both report the flow to the `L2NativeTokenVault` bookkeeping first (the holder itself stores
  nothing). Its balance means "funds the chain can still mint";
  force-sent funds (refund recipient, selfdestruct on ZK OS) only skew the `totalSupply()` view, never
  bridging accounting.
  - The operator must keep the base-token total supply below `2^127`, otherwise the holder's balance
    could underflow; overflow is impossible since users can only gain what the holder loses.
  - On ZKsync OS the holder's initial balance is minted by `L2BaseTokenZKOS.initL2()` via a raw call to
    `MINT_BASE_TOKEN_HOOK` with the amount abi-encoded as a `uint256`; the hook credits the caller and
    only accepts calls from the L2 base-token address.
  - On Era, all ETH transfers route through the `MsgValueSimulator` (which emits `Transfer` events), so
    a single holder implementation works uniformly on both VMs.
- In `NativeTokenVaultBase._getTokenAndBridgeToChain`, a base-token burn requires `amount == msg.value`.
  If the base token is bridged (always the case on L2), the value goes through
  `BaseTokenHolder.burnAndStartBridging`; the native branch (plain accounting) only occurs on L1 for ETH.
- The `L2NativeTokenVault` stores the base token's origin token, name, symbol and decimals
  (set in `initL2`/`updateL2`) and maps its asset ID to the `L2BaseToken` system contract address.
  `BASE_TOKEN_ASSET_ID` is frozen once set — changing it would strand in-flight bundles whose snapshotted
  destination base-token asset ID no longer matches.
- `L2WrappedBaseToken` is the canonical WETH-style wrapper: no silent fallback, `receive`, `permit`,
  `depositTo`/`withdrawTo`. Its `bridgeMint` always reverts (use `deposit`); `bridgeBurn` burns and returns
  ether to the bridge. It carries the _base token's_ asset ID — the wrapper has no asset ID of its own.
  Still upgradeable for now; upgradeability will be removed later to make it trustless.

## L2 asset bookkeeping

The chain keeps a small amount of local token bookkeeping in the `L2NativeTokenVault`, the contract every
asset already flows through (a separate write-only `L2AssetTracker` system contract existed in unreleased
v31 code and was removed). Apart from `bridgedOut`, this is write-mostly data: correctness of transfers is
guaranteed by ZK proofs (plus 2FA on ZKsync OS chains), not by these balances, and the mappings may be
removed later (do not rely on them). The vault's own `DEPRECATED_chainBalance` and the removed
`AssetTrackerBase` / `L1AssetTracker` / `GWAssetTracker` (cross-chain token-balance migration) are gone;
the `0x1000f` (L2AssetTracker) and `0x10010` (GWAssetTracker) addresses stay reserved, the latter keeping
its empty compatibility stub because pre-v31 chains did deploy code there.

### `L2NativeTokenVault`

- `bridgedOut[assetId]` is the net amount of an **L2-native** token currently bridged away from this
  chain: `_handleBridgeToChain` increases it, `_handleBridgeFromChain` refuses an inbound amount that
  exceeds it (`InsufficientChainBalance`). This is the active safety property previously derived from
  `MAX_TOKEN_BALANCE - L2AssetTracker.chainBalance`; unlike the raw vault balance it is unaffected by
  later direct token donations. The mapping and both handlers live in `NativeTokenVaultBase` (shared with
  `L1NativeTokenVault`); the field takes a slot from the base storage gap, which no deployed vault ever
  wrote, so already-deployed layouts are preserved.
- `interopInfo[assetId]` (`totalWithdrawalsToL1`, `totalSuccessfulDepositsFromL1`) is the L2-side
  accounting used to compute the amount to keep on L1 during the L1 -> Gateway migration. A flow is only
  counted when the counterpart chain is L1 _and_ the chain currently settles on L1; `totalWithdrawalsToL1`
  is consumed once during that migration and must stay append-only. The base token's counters live here
  too, under `BASE_TOKEN_ASSET_ID`, reported by the `BaseTokenHolder` (below). For the base token, failed
  deposits are refunded on L2 to the `refundRecipient` rather than claimed on L1, so the gap between
  initiated deposits and this counter is not uniformly "claimable on L1" across asset types.
- `preTrackingTotalSupply[assetId]` records the token's net inbound flow — total successful deposits
  minus total successful withdrawals — accumulated before this bookkeeping existed. For a bridged token
  (the base token included) that is exactly its pre-tracking `totalSupply()`; native tokens offset the
  same net flow by `type(uint256).max` (the removed tracker's infinite-deposit convention):
  `2^256 - 1 - bridgedOut`. Newly registered tokens start at the zero-flow baseline (`0` bridged,
  `max` native).
- `isAssetTracked[assetId]` guards the one-time initialization of the two fields above for a legacy
  L2-native token: its outstanding amount is seeded from the vault's current escrow (indistinguishable
  direct donations are conservatively treated as escrow, since they are effectively frozen). Seeding
  happens lazily on the token's first touch — before the operation changes any supply or escrow — or
  eagerly by anyone via `trackLegacyToken`; it is idempotent, newly registered tokens are marked tracked
  immediately, and `trackLegacyToken` rejects the base token.
- The base token's baseline is recorded by `trackBaseToken` (upgrader-only, idempotent), which the
  upgrade/genesis init helper calls on both paths: its `totalSupply()` at that moment — the pre-upgrade
  supply on an upgraded chain, zero at genesis — is the pre-tracking net inbound flow, and every later
  flow is reported by the holder into `interopInfo`. Tracking it from any later moment would fold
  already-recorded flows into the baseline, which is why `trackLegacyToken` cannot be used instead.

### `BaseTokenHolder` (base token)

The holder escrows the base token, so its contract-level bridge flows converge here; each one is reported
to the vault, which records it under `BASE_TOKEN_ASSET_ID` in the same `interopInfo` used for every other
asset (`recordBaseTokenBridgingToChain` / `recordBaseTokenBridgingFromChain`, holder-only).
`burnAndStartBridging` reports outbound flows and `give` reports inbound interop flows before the external
transfer. Bootloader-minted L1 deposits are reported through `recordBaseTokenDeposit` only where the mint
is a contract call (`L2BaseTokenEra.mint`); on ZKsync OS the VM credits deposits by moving the holder's
balance directly, so the base token's `totalSuccessfulDepositsFromL1` counter is **not exhaustive** there.

- The pre-v31 total supply of an upgraded ZKsync OS chain lives in `L2BaseTokenZKOS.zkosPreV31TotalSupply`,
  populated while the chain ran draft-v31 (via the since-removed backfill service transaction). This
  release has no backfill path: the v32 upgrade of a ZKsync OS chain is forbidden on L1
  (`V32UpgradeZKsyncOS`) unless `baseTokenHasTotalSupply` was set by the draft-v31 backfill
  _and_ the backfill's L2 execution is proven — a `PriorityOpLowerBound` registry permissionlessly pins a
  priority-op count observed after the flag was set, and the upgrade requires all ops below it to be
  processed. So `totalSupply()` is always available on upgraded chains; fresh chains have no pre-v31
  history and keep zero.
- `recoverBaseToken` (NativeTokenVault only) returns the escrow of a failed/timed-out base-token bridge-out
  and asserts the two invariants that make the recovery accounting-neutral: the destination was not L1
  (`RecoverToL1NotSupported`, so `totalWithdrawalsToL1` stays append-only) and the base token is not native
  to this chain (`BaseTokenNativeToThisChain`, so the vault's `bridgedOut` holds nothing to re-credit).

## L1Nullifier and failed-deposit recovery

`L1Nullifier` tracks initiated L1 -> L2 deposits so users can claim funds back if the L2 execution fails.

- `bridgehubConfirmL2TransactionForwarded` (asset router only) records
  `depositHappened[chainId][l2TxHash] = txDataHash`, refusing overwrites.
- `bridgeRecoverFailedTransfer` (permissionless) / `bridgeConfirmTransferResult` verify, via
  `MessageRoot.proveL1ToL2TransactionStatusShared`, a Merkle proof that the L1 -> L2 transaction reached
  the claimed status; check that the recomputed `txDataHash` matches the recorded deposit; delete the
  record (each deposit is claimable once); and forward to `L1AssetRouter.bridgeConfirmTransferResult`,
  which dispatches to the asset handler's `IL1AssetHandler.bridgeConfirmTransferResult`.
- `L1NativeTokenVault.bridgeConfirmTransferResult` only accepts `TxStatus.Failure` and non-zero amounts. It
  resolves the token's origin chain (with fallbacks for pre-registration legacy deposits based on vault /
  nullifier balances) and calls `_disburseFailedTransfer`, which refunds the `_depositSender`: unlock via
  `_withdrawFunds` for a native asset, re-mint via `bridgeMint` for a bridged one. WETH deposits are no
  longer allowed, but legacy WETH deposits may still be claimed; no wrap/unwrap is performed.
- `_disburseFailedTransfer` (in `NativeTokenVaultBase`) is shared by this failed-deposit claim path and the
  atomic-interop recovery path below, and applies the same "decrease chain balance before releasing funds"
  ordering as `bridgeMint`. On L2 it is overridden to route the base token to
  `BaseTokenHolder.recoverBaseToken` (the base token is escrowed off-vault, the inverse of
  `burnAndStartBridging`).

## Atomic-recovery hook

`L2AssetRouter` implements `IAtomicRecoverable.recoverAtomicCall`, the timeout-refund hook of the atomic
interop (IMT) flow — see {protocol-docs/atomicity/flow.md} for the full flow. Summary:

- Callable only by the canonical `AtomicFlowManager`, a genesis built-in at a fixed address
  (`L2_ATOMIC_FLOW_MANAGER_ADDR`); on chains without the atomic-flow stack nothing is deployed there, so
  the gate never passes.
- Given the original bundle call's calldata, it recognizes only `finalizeDeposit` calls and returns `false`
  for anything else, so the manager can skip non-recoverable calls in a mixed bundle. Returning `false`
  (rather than reverting) is what keeps an unrecognized call from failing the whole refund — but a
  _recognized_ call can still revert: on malformed `finalizeDeposit` payload (the `abi.decode` throws) or
  if the downstream `bridgeRecoverFailedTransfer` fails. Such a revert takes the entire `claimRefund`
  with it; see {protocol-docs/atomicity/recovery.md#the-walk-is-all-or-nothing-not-per-call-isolated}.
- For a recognized burn it calls `IL2AssetHandler.bridgeRecoverFailedTransfer(destChainId, assetId,
mintData)` on the asset handler registered for the asset (`assetHandlerAddress[assetId]` — the same
  lookup the burn used; the NTV for standard tokens, a custom handler otherwise), forwarding the
  bundle's mint data verbatim; the handler refunds the data's `originalCaller` (the source depositor)
  regardless of the intended `remoteReceiver`, reversing the `bridgeBurn` performed at send time by
  `initiateIndirectCall`. `_chainId` must be the burn-time destination chain so the accounting reverses
  correctly. Two caveats: every calldata format the router has ever produced must stay recognized
  forever (see the `IMPORTANT` note in `recoverAtomicCall` and
  {protocol-docs/atomicity/security.md#known-issues-to-be-fixed-in-this-release}), and overwriting a
  registered handler misroutes in-flight recoveries
  ({protocol-docs/atomicity/security.md#known-issues-and-accepted-limitations}).
- Recovery to L1 is rejected (`RecoverToL1NotSupported`), see below.

## Security notes

- **L2 -> L1 withdrawals are never revertable.** The `InteropCenter` rejects L1-destined atomic bundles at
  send time, and both `L2AssetRouter.recoverAtomicCall` and `BaseTokenHolder.recoverBaseToken` assert
  `destChainId != L1_CHAIN_ID`. The reason is
  accounting: `totalWithdrawalsToL1` is consumed exactly once during the L1 -> Gateway migration and must
  stay append-only; a revertable withdrawal would corrupt the migrated balance.
- **Message forgery**: finalization is only reachable through the interop handler with a proven message,
  the sender must be the counterpart asset router, the payload selector is pinned to `finalizeDeposit`, and
  the sender chain ID must equal the payload's source chain ID.
- **Forged bridged tokens**: on L1, an inbound transfer of an L1-native asset exceeding the outstanding
  `bridgedOut` amount is blocked rather than recorded.
- **Reentrancy/ordering**: chain-balance bookkeeping is always updated before funds are released, so a
  malicious token or ETH recipient cannot overwrite the transient values from `L1Nullifier`.
- **Malicious source chains**: mint data comes from the (potentially malicious) source chain; handlers must
  treat it as "chain X claims asset Y should be minted with data Z" and validate accordingly.

## Legacy compatibility

- The legacy **withdrawal** path is still supported: `L1AssetRouter.finalizeWithdrawal` ->
  `L1Nullifier.finalizeWithdrawal` parses the old message format and nullifies via
  `isWithdrawalFinalized`. Numerous
  `__DEPRECATED_*` storage slots remain across `L1AssetRouter`, `L2AssetRouter`, `L1Nullifier`,
  `L2NativeTokenVault` and `L1NativeTokenVault` solely to preserve the upgradeable
  storage layouts of already-deployed proxies; they are never read or written and must not be reused.
- Legacy bridged tokens on L2 may predate the NTV: `BridgedStandardERC20.onlyNTV` lazily migrates them by
  setting `nativeTokenVault` to `L2_NATIVE_TOKEN_VAULT_ADDR` and deriving the asset ID on first use.
  `addLegacyTokenToBridgedTokensList` backfills such tokens into the vault's `bridgedTokens` enumeration,
  and `L2NativeTokenVault.trackLegacyToken` seeds a legacy L2-native token's outstanding `bridgedOut`
  amount from the vault escrow.
- `L2NativeTokenVault.l2TokenAddress(l1Token)` is the legacy getter mapping an L1 token to its L2
  counterpart; the L1-origin CREATE2 salt (plain L1 address) keeps legacy token addresses stable.
- `updateL2` on `L2AssetRouter`/`L2NativeTokenVault` resets the owner to the aliased L1 governance if it
  differs (pre-v31 ZKsync OS testnets ran with a temporary multisig owner).

## Bridged token contracts

- `BridgedStandardERC20`: beacon-proxied ERC20 (with permit) minted/burned only by the NTV. It stores
  which of `name`/`symbol`/`decimals` the origin token actually implemented and reverts on the missing
  getters, mimicking the origin token. `reinitializeToken` lets the beacon owner update metadata, one
  version step at a time so reinitialization can never be accidentally disabled. No custom token logic
  (e.g. rebasing) is supported.
- `L2WrappedBaseToken`: see "Base-token handling" above.
