# Chain lifecycle: creation, registration, and migration

This document is the source of truth for how a ZK chain is created on L1, how it becomes reachable
for interop, and what the settlement-layer migration machinery does (and why it is disabled in the
current release). Contract doc comments reference this file instead of restating the narrative.

Related documents, which are the source of truth for their own topics:

- {protocol-docs/message-root.md} — the `MessageRoot` tree structure, the v31 vs v32 batch-root
  flows (`addChainBatchRoot` vs `addChainBatchRootV32`), and interop-root import/verification.
- {protocol-docs/interop.md} — the interop message path (`InteropCenter`, `InteropHandler`,
  bundles, interop roots).
- {protocol-docs/atomicity/README.md} — the atomic (IMT-based) interop protocol, its proofs, and the
  full statement of the timeout-protocol preconditions.

## Chain creation (`createNewChain`)

New chains can only be registered on the Bridgehub deployed on L1 (`L1Bridgehub.createNewChain`,
callable by the Bridgehub owner or admin). In one transaction it:

1. Validates the chain params and records `chainTypeManager[_chainId]`,
   `baseTokenAssetId[_chainId]`, and `settlementLayer[_chainId] = block.chainid` (L1).
2. Asks the CTM to deploy the chain's diamond (`IChainTypeManager.createNewChain`), which runs
   `DiamondInit` (see below). A zero returned address reverts, as protection against a malicious
   CTM.
3. Registers the diamond in the Bridgehub (`_registerNewZKChain`) and marks the base-token
   `assetId` as registered.
4. Adds the chain to the L1 `MessageRoot` with starting batch number 0
   (`messageRoot.addNewChain(_chainId, 0)`) — the chain gets a chain-id leaf in the aggregated
   `sharedTree` and an empty per-chain `chainTree`.
5. Seeds the chain's genesis batch root (`messageRoot.seedGenesisRoot(_chainId)`, see below) and
   emits `NewChain`.

### Genesis chain state (`DiamondInit`)

`DiamondInit` initializes the diamond's storage: verifier(s), admin, base-token asset id, protocol
version, fee params, the priority tree, and the `nativeTokenVault` reference (the L2 built-in
constant `L2_NATIVE_TOKEN_VAULT_ADDR` when running under the L2 Bridgehub, otherwise derived from
the Bridgehub's asset router — no immutable needed).

For ZKsync OS chains (`IS_ZKSYNC_OS`) it additionally stores the chain's genesis (batch 0) chain
batch root: `s.l2LogsRootHashes[0] = ChainBatchRootTree.genesisChainBatchRoot()`. Batch 0 has no
L2->L1 logs, no multichain root, and a freshly seeded (empty) interop commitment tree at both batch
boundaries, so this value is exact and computable in advance (see `ChainBatchRootTree` for the
fixed 8-leaf layout of a ZKsync OS chain batch root).

### Genesis batch root seeding

Called by the Bridgehub right after registration, inside the same `createNewChain` transaction.
It is a one-time, Bridgehub-only entry point, and a no-op for EraVM chains
(`IGetters.getZKsyncOS() == false`).

For a ZKsync OS chain it pulls the genesis root back from the chain itself
(`l2LogsRootHash(0)`, stored by `DiamondInit`) — keeping the "chain reports its own roots"
interface intact; the `MessageRoot` never computes a chain's batch-root format — and pushes it as
the batch-0 leaf of the chain's tree, updating the aggregated shared root. Guards: the read root
must be non-zero (a zero read is a bug), the chain must be registered, `currentChainBatchNumber`
must be 0 (ruling out chains onboarded at a non-zero starting batch and chains that already settled
real batches), and the batch-0 root must not already exist. `currentChainBatchNumber` stays 0, so
the first real batch continues at 1 exactly as without the genesis leaf.

Why this exists: the atomic-interop timeout protocol requires that every chain interop can target
has **at least one batch leaf inside the settlement layer's message root** — otherwise a leg on a
chain that halts before ever settling could neither finalize nor be proven timed out. Seeding at
creation satisfies this for fresh chains; see {protocol-docs/atomicity/proofs.md#completeness} for the proof-level
reasoning.

Chains added to a message root with a **non-zero** starting batch number (already-deployed chains
being onboarded, settlement-layer migrations) are never seeded: a real batch with that number
exists elsewhere, and a synthetic leaf would diverge from it. For them the guarantee is enforced at
interop-registration time instead (next section).

## Interop registration (`ChainRegistrationSender`)

`ChainRegistrationSender` registers a chain on another chain's `L2Bridgehub`
(`registerChainForInterop`). There are two entry points, differing only in who pays:

- **`registerChain(chainToBeRegistered, chainRegisteredOn)`** — the free ease-of-use path. It sends
  the registration as an **L2 service transaction**
  (`IMailbox.requestL2ServiceTransaction` on the target chain), so the caller supplies no base
  tokens at all. Because it is free it is rate-limited structurally: the
  `chainRegisteredOnChain[a][b]` mapping makes it callable **once per ordered chain pair**
  (`ChainAlreadyRegistered` on a repeat), which prevents spamming service transactions.
- **`bridgehubDeposit`** — the caller-funded path, driven through the Bridgehub's two-bridges flow.
  Anyone can trigger it, but the caller pays the base tokens for the L1->L2 transaction; no ETH
  `msg.value` is accepted. Not once-per-pair, since the caller bears the cost.

Both call `_checkSettlementLayers` directly and build their payload with the shared
`_getL2TxCalldata`, so every check below applies on both paths regardless of who pays.

Checks performed before sending the registration:

- The chain to be registered is known to the Bridgehub (its `baseTokenAssetId` is non-zero).
- Both chains settle on the **same** settlement layer (`ChainsSettlementLayerMismatch` otherwise).
  Both settling directly on L1 is permitted as of v32: L1 itself builds interop roots
  (`MessageRootBase.addChainBatchRootV32`) and serves the corresponding inclusion proofs, so
  L1-settled chains participate in interop without a gateway. (In v31 this case was rejected with
  the now-removed `ChainsSettlingOnL1` error.)
- The chain to be registered has at least one batch leaf in this layer's message root
  (`messageRoot.chainTreeLeafCount(chainId) > 0`), else it reverts with
  `ChainHasNoBatchesInMessageRoot`. This is the second enforcement point of the atomic-interop
  timeout precondition: interop towards a chain is only enabled once the chain both has its
  `sharedTree` leaf and has a batch in its chain tree.

No backfill of pre-existing chains is needed for this gate: during v31 the ZK Gateway was never
activated and registration required that a chain does **not** settle on L1, so at the start of v32
no chains have been registered for interop — every chain passes through this gate (and gets its
tree populated) before interop can target it.

## Settlement-layer migration (`ChainAssetHandler`)

### Role

The chain asset handler treats chains themselves as bridgeable assets of their CTM: `bridgeBurn`
on the source settlement layer collects the chain's migration data (protocol version, batch
number, base-token bridging data, etc.) and de-registers it locally; `bridgeMint` on the
destination layer deploys/re-registers the chain there. Both are callable only via the asset
router, and both are guarded by the runtime `migrationPaused` flag (a governance pause used for
upgrades) **and** the release-level migrations ban below. On migration to a settlement layer,
`bridgeBurn` also fills `originToken`/`originChainId` of the base-token bridging data, which the
destination's `L2NativeTokenVault.updateL2` consumes to initialize the chain's base token.

`L1ChainAssetHandler.isReadyForMigration` additionally requires: the chain is not pre-v31
(per the L1 `MessageRoot`), its base token is registered in the L1 `NativeTokenVault`
(`tokenAddress(baseAssetId) != address(0)`, otherwise L1->L2 base-token deposits would not work
on the destination), and the base token supports `totalSupply()` (true for everything except
pre-v31 ZKsync OS chains, where the value must first be backfilled).

### v32: chain migrations are explicitly disabled

In the v32 release the protocol operates under the invariant that **all chains settle on L1**, and
chain migrations between settlement layers are explicitly disabled to remove migration-related
risks for the time being:

- The switch is `CHAIN_MIGRATIONS_ENABLED = false` in `common/Config.sol`, surfaced via
  `ChainAssetHandlerBase.migrationsEnabled()` and enforced by the `whenMigrationsEnabled` modifier
  on `bridgeBurn` and `bridgeMint`, which revert with `ChainMigrationsDisabled`.
- This is a **release-level** ban, unlike the runtime `migrationPaused` flag: it cannot be lifted
  by a governance call and requires a protocol upgrade that redeploys the chain asset handler with
  the constant set to `true`.
- Recovery of a failed migration (`bridgeConfirmTransferResult`) is intentionally **not** gated by
  the flag, since it only ever returns a chain back to settling on L1.
- The whole migration machinery (chain asset handlers, `Migrator` facet, migration intervals,
  migration numbers) is kept intact and covered by tests, so a future release can bring settlement
  layers (e.g. ZK Gateway) back by flipping the constant. `_chainMigrationsEnabled()` is `virtual`
  only so dev/test variants can re-enable migrations for coverage; production contracts must not
  override it.

### Migrated chains and the message root (IMPORTANT)

A chain registered on a settlement layer during `bridgeMint` (non-zero batch number) gets **no
genesis batch leaf** in that layer's message root — its chain tree stays empty until its first
settlement there. This is fine under the current assumption that **only the L1 message root is
used to anchor atomic-interop timeout proofs**: fresh chains are seeded on L1 at creation, and
`ChainRegistrationSender` refuses to enable interop towards a chain with an empty tree. If a
non-L1 message root is ever used as the timeout-proof anchor, migrated chains need an equivalent
guarantee (e.g. carrying the chain's current IMT root in the migration data and seeding a leaf
from it).

### Pausing deposits on the settlement layer

`L1ChainAssetHandler.requestPauseDepositsForChainOnGateway(chainId)` lets a chain that is about to
migrate away from a settlement layer request that deposits to it be paused there. It is callable
only by the chain's diamond, requires the chain's settlement layer not to be L1, and forwards the
request as an L2 service transaction to the settlement layer's `L2ChainAssetHandler` (the chain
asset handler is an authorized service-transaction sender there). This re-homes the cross-layer
message that previously went through the removed asset tracker.

## ZKsync OS genesis force deployments: atomic-interop built-ins

Two new L2 built-ins support atomic interop (protocol details in
{protocol-docs/atomicity/README.md}):

- `L2InteropCommitmentTree` at `0x10012` (`L2_INTEROP_COMMITMENT_TREE_ADDR`) — the per-chain
  append-only Indexed Merkle Tree of leg commitments. Its storage layout is consensus-critical:
  the ZKsync OS bootloader reads the IMT root directly from its storage at every batch boundary.
- `AtomicFlowManager` at `0x10014` (`L2_ATOMIC_FLOW_MANAGER_ADDR`) — the fund-touchless flow
  coordinator. Address `0x10013` is intentionally reserved/empty.

They are predeployed **only** in the ZKsync OS genesis (registered in the genesis gen tool,
`tools/zksync-os-genesis-gen`); they have no constructors, so one-time setup happens in `initL2`
calls made by `L2GenesisForceDeploymentsHelper._initializeV31Contracts`, gated on
`_isZKsyncOS && _isGenesisUpgrade`:

- `L2InteropCommitmentTree.initL2()` seeds the IMT with its `{0,0,0}` sentinel head leaf (reverts
  if already seeded).
- `AtomicFlowManager.initL2(l1ChainId)` records the L1 chain id; in this release every flow's
  settlement layer must equal it.

This is the only one-time state setup: all cross-contract wiring (the tree's appender, the
manager's tree / interop center / interop handler references) uses canonical fixed built-in
addresses, so there are no wiring parameters, and the manager never custodies funds (source burns
flow through the normal interop path; destination mints go through the `InteropHandler`).

The `_isGenesisUpgrade` gate matters: a pre-existing chain being upgraded to v31 has no code at
`L2_INTEROP_COMMITMENT_TREE_ADDR`, so calling `initL2()` there would revert the whole upgrade
transaction — such chains simply do not get atomic interop.
