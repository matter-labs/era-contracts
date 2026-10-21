# L1SLOAD

From v36, L2 contracts on ZKsync OS chains settling on L1 read L1 storage through the `L1SLOAD` precompile at
`0x101` ([RIP-7728](https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7728.md)). The values are read at the
chain's **anchored L1 block**: an L1 block hash the operator imports through the existing interop-root channel, which
L1 checks at batch execution like every imported root. ZKsync OS verifies each value against that block's state root
with a Merkle-Patricia proof.

Interop gating is the first user. L1 is its only source of truth: chains read the peer whitelist, the peers' base
tokens and the suspensions from `ChainRegistrationSender`, instead of having them pushed by service transactions.

|                     | Before v36                                                    | From v36                                                                 |
| ------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Whitelist on L2     | `L2Bridgehub.isPeerAllowed`, written by a service transaction | read from L1 at the anchor ([gating](#interop-gating-through-l1-reads))  |
| Peer's base token   | `L2Bridgehub.baseTokenAssetId`, written by the same push      | `ChainRegistrationSender.interopBaseTokenAssetId`, read from L1          |
| Turning a chain off | none short of an upgrade                                      | `suspendInterop`, one L1 transaction ([suspending](#suspending-a-chain)) |
| Gating change on L2 | when the service transaction executes                         | when the chain imports an anchor taken after the change                  |

## Safety argument

A batch whose L1 reads don't come from L1 can't be executed:

- **The anchor is a real L1 block.** At execution `Executor._verifyDependencyInteropRoots` takes each imported
  anchor's hash and timestamp from `L1MessageRoot.recordedL1BlockHash`, which only L1 writes
  ([anchors](#anchors)). The anchor is folded into the batch's dependency-roots rolling hash, which the proof
  commits to.
- **The values are that block's state.** ZKsync OS checks the block header against the anchor hash and each value's
  account and storage proofs against the header's state root, inside the proven state transition. A missing or
  invalid witness fails the transaction or the block; it never yields a value.
- **The anchor is recent.** Every gating read refuses an anchor older than `L1_ANCHOR_MAX_LAG` in L2 block time
  ([freshness](#freshness)), Priority Mode included.
- **Failures close.** With no anchor, a stale anchor or the [flag](#chain-config-flag) off, every gating read
  reverts (`L1AnchorStale`, `L1SloadFailed`): the chain can neither send interop nor accept it.

The storage slots of the gating mappings are an L2-facing ABI ([reading L1 state](#reading-l1-state)).

## Anchors

- **Reserved id.** Anchors are imported through the interop-root channel with `chainId = L1_BLOCK_HASH_IMPORT_ID =
uint256(keccak256("zksync.l1-block-hash-import")) - 1`, `blockOrBatchNumber` = the L1 block number, `sides =
[blockHash]` and `timestamp` = the time L1 recorded the hash. No chain can have this id: the Bridgehub caps chain
  IDs at `type(uint48).max`.
- **L1 record.** `L1MessageRoot.recordL1BlockHash()` stores `blockhash(block.number - 1)` with `block.timestamp`
  under `block.number - 1`, emits `L1BlockHashRecorded`, and `recordedL1BlockHash(n)` returns it. Every
  `commitBatches` on L1 of a chain with L1SLOAD on calls it, so operators send no transaction for it; chains with
  the flag off don't pay for it. Commits don't wait for proofs, so a prover outage doesn't stop new anchors. It stays
  permissionless, and is a no-op when the block is already recorded, so the chains committing in one L1 block share
  one record. When nothing commits, for example on an idle ecosystem, the server's keeper calls it itself. The record is permanent, so an anchor stays verifiable at
  execution however long ago it was taken; the EVM's `blockhash` only reaches 256 blocks back.
- **Import on L2.** `L2InteropRootStorage` runs the checks of every import (one non-zero side, non-zero
  timestamp), then requires the block to be newer than the current anchor (`L1AnchorNotNewer`), so the anchor
  only moves forward and block 0 can't be anchored. It writes the anchor's hash, number and L1 time to the fixed
  slots `keccak256("zksync-os.l1sload.anchor.block-hash")`, `keccak256("zksync-os.l1sload.anchor.block-number")`
  and `keccak256("zksync-os.l1sload.anchor.timestamp")` (ZKsync OS reads the hash, [freshness](#freshness) the
  time), and emits `InteropRootAdded` with exactly one side, the block hash, so the ZKsync OS
  event hook folds it into the batch's dependency-roots rolling hash. The anchor is stored only there: neither
  `interopRoots` nor `latestInteropRootTimestamp` record it. `L1SLOAD` reverts while no anchor is set.
- **Check on L1.** `Executor._verifyDependencyInteropRoots` takes the expected root and timestamp of an anchor from
  `recordedL1BlockHash(blockNumber)`, with the same checks as for message roots
  ({protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}).
- **Not a message root.** `interopRoots(L1_BLOCK_HASH_IMPORT_ID, n)` stays zero, so `L2MessageVerification`'s
  non-zero root check rejects every proof against an anchor: a block hash can never prove a message.

## Freshness

Every gating read checks the anchor's age first: `L1View` reverts with `L1AnchorStale` when `block.timestamp >
anchorTimestamp + L1_ANCHOR_MAX_LAG` (1 hour), so gating fails closed on a stale view of L1. `anchorTimestamp` is the
L1 time the anchor was recorded at; the import writes it and execution checks it against the L1 record
([anchors](#anchors)).

- The bound holds for every read, however the operator composes batches.
- A chain that never imported an anchor has `anchorTimestamp = 0` and reads nothing, whatever the clock.
- In Priority Mode, whose batches can't contain the service transaction that imports anchors, reads fail once the
  last anchor is past the lag instead of seeing stale state.

`L1View` is the gating reader. Other contracts that call `0x101` directly pick their own rule from
`IL2InteropRootStorage.l1AnchorTimestamp()`. The Executor checks no freshness, and `StoredBatchInfo.timestamp` stays
0 for ZKsync OS batches.

## Settlement layer

Anchors are checked against `L1MessageRoot.recordedL1BlockHash`, the L1 record, which a settlement layer's message
root doesn't have. A chain with L1SLOAD on must therefore settle on L1. The contracts don't extend the Gateway for it.

## Reading L1 state

`L1Reads.l1sload` wraps the precompile (input `l1Contract || key_1 || ... || key_k`, `1 <= k <= 5`, output `k`
words). The precompile has no ABI, so this is a low-level `staticcall`, and its failure is surfaced as
`L1SloadFailed`, never handled. Any contract may call `0x101`; the precompile's per-call caps and its gas
(`2000 + 2000·k`) and native charges bound the work.

`L1View` reads only `ChainRegistrationSender`, with one precompile call per check:

| Check                          | Keys read                                                                                                |
| ------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `isReceiveAllowed(self, peer)` | `interopPeerAllowed[self][peer]`, `interopSuspended[self]`, `interopSuspended[peer]`                     |
| `sendTarget(self, peer)`       | the three above, `interopPeerAllowed[peer][self]` and `interopBaseTokenAssetId[peer]` (the maximum of 5) |
| `baseTokenAssetId(chain)`      | `interopBaseTokenAssetId[chain]`                                                                         |

The slots of these mappings in the implementation layout (152, 153, 154) are an L2-facing ABI: an L1 upgrade that
moves them silently breaks every L2 reader. They are pinned in `Config.sol` and by `L1ViewStorageLayout.t.sol`,
which writes through the real `ChainRegistrationSender` and reads the computed slots back.

`L1MessageRoot.interopEnabled` is not read. `allowInteropPeer` requires both chains to be enabled, and enabling is
one-way ({protocol-docs/interop-gating.md#enabling-interop}), so `interopPeerAllowed[self][peer]` implies that both
chains are enabled.

## The base token snapshot

`ChainRegistrationSender.allowInteropPeer(chainId, peer)` writes `interopBaseTokenAssetId[peer] =
Bridgehub.baseTokenAssetId(peer)`, after the checks the retired push ran when it built its service transaction: the
asset id is non-zero (`ZKChainNotRegistered`) and the peer has a batch in L1's message root
(`chainTreeLeafCount(peer) > 0`, `ChainHasNoBatchesInMessageRoot`).

- **It can't drift.** The Bridgehub sets a chain's `baseTokenAssetId` when the chain is created and never changes
  it, so every write of the snapshot writes the same value. It is never deleted.
- **It is the interop registration.** A chain "is registered for interop" when it has a snapshot. The leaf-count
  check is what makes a snapshot imply MessageRoot presence, which `AtomicFlowManager.append` relies on for every
  co-leg's source chain ({protocol-docs/atomicity/security.md#timeout-protocol-preconditions}); it reads it with
  `L2Bridgehub.interopBaseTokenAssetId`. `L2AssetRouter` takes a destination's base token from it too.

## Interop gating through L1 reads

The L2 Bridgehub reads the L1 `ChainRegistrationSender` at `l1ChainRegistrationSender()`, the unaliased
`chainRegistrationSender` that the genesis force deployments store
(`FixedForceDeploymentsData.aliasedChainRegistrationSender`). `self` is `block.chainid`.

- **Receive filter.** `isPeerAllowed(peer)` is `interopPeerAllowed[self][peer]` and neither chain suspended. It is
  the [receive filter](./interop-gating.md#receive-filter).
- **Send.** `interopSendTarget(peer)` returns whether both admins allowed each other and neither chain is suspended,
  and the peer's base token snapshot. `InteropCenter` reverts with `DestinationChainNotRegistered` when the
  snapshot is zero and with `DestinationChainNotAllowed` when sending is not allowed, so a one-sided whitelist
  can't start a flow ([K1](./interop-gating.md#k1-stuck-flows)).
- **Suspension.** `ChainRegistrationSender.suspendInterop(chainId)` / `resumeInterop(chainId)` (owner only) switch a
  chain off and on again in both directions, for every chain at once, with one L1 transaction. They touch neither
  the whitelist, nor the snapshots, nor `interopEnabled`, which the vault's pool accounting keys on
  ({protocol-docs/interop-gating.md#interop-pool}).
- **No push.** `allowInteropPeer` and `deregisterInteropPairs` only write L1 state. The service transactions, the
  `bridgehubDeposit` resubmission and the L2 Bridgehub's `allowInteropPeer` / `deregisterChainForInterop` are gone,
  and `ChainRegistrationSender` sends no service transactions, so `ZKChainBase.onlyServiceTransaction` admits only
  the chain asset handler. The mirrored mapping's slot is kept as `__DEPRECATED_isPeerAllowed`. Entries the push
  wrote into the L2 Bridgehub's `baseTokenAssetId` stay, but no gating reads them.

## Chain config flag

`L1SLOAD` is switched on per chain by the `l1sload_enabled` chain-config word ({protocol-docs/chain-config.md#l1sload}),
which the batch public input commits to. With it off, ZKsync OS doesn't register the precompile and `0x101` behaves
like an empty account, so every L1 read reverts. Because interop gating reads L1:

- `L1MessageRoot.enableInterop` requires the flag (`L1SloadNotEnabled`);
- `setZKsyncOSL1SloadEnabled(false)` reverts while the chain's interop is enabled (`L1SloadRequiredByInterop`).

## Upgrade from v35

The v36 upgrade (`CoreUpgrade_v36`, `CTMUpgrade_v36`) installs the new `L1MessageRoot`, `ChainRegistrationSender`
and `L1AssetRouter`, the new Admin, Getters, Mailbox, Executor and Committer facets, and the L2 built-ins whose code
changed, which the release pair derives on-chain (among them `L2Bridgehub`, `InteropCenter`, `AtomicFlowManager`,
`L2AssetRouter` and `L2InteropRootStorage`).

- **Base token snapshots.** v35 kept no snapshot, so after the upgrade every pair allowed under v35 would read a zero
  base token and stop sending. The `ChainRegistrationSender` swap calls `initializeUpgrade()` (`reinitializer(2)`,
  proxy admin only), which writes the snapshot of every chain in `Bridgehub.getAllZKChainChainIDs()` that has
  interop enabled and a batch in the message root, unless it already has one. Under v35 `allowInteropPeer` accepted
  only peers that were registered, enabled and had a batch in the message root, so this covers every peer a v35
  admin allowed; a snapshot of an enabled chain nobody allowed only marks it registered, which the leaf check makes
  true. Mappings can't be enumerated, and this rule needs no list authored off-chain.
- **The flag.** A chain whose interop was enabled under v35 would cross with interop on and `l1sload_enabled` off,
  which v36 forbids. So the chain's upgrade turns the flag on: `DefaultUpgrade.upgradeFromTransition` sets it, with
  the setter's `NewZKsyncOSL1Sload(false, true)`, for a chain on L1 whose interop is enabled. Every committed batch has
  executed by then, so the change lands at a configuration boundary. The first batch after the upgrade commits the
  seven-word chain config hash with the flag on, so the server reads the flag from L1 for it. Chains without interop
  keep it off. Every later transition repeats the step, and finds nothing to do once the flag is on.
- **The first anchor.** The upgrade seeds no anchor: a seeded one would be an unchecked L1 state. The first record
  comes from the chain's first commit with the flag on (its upgrade batch, for a chain the upgrade turned it on for)
  or from the server's keeper. The server imports it once it is final on L1 (about 13 minutes), in a later block.
  Until then the chain's gating reads revert and its interop pauses.
- **Stale L2 state.** The L2 Bridgehub's v35 whitelist stays under `__DEPRECATED_isPeerAllowed`, and its
  `baseTokenAssetId` entries for peers stay but are not read for gating.
- **Enabling interop.** `enableInterop` reverts with `ChainPredatesL1Sload` for a chain still on pre-v36 facets, which
  route no `isZKsyncOSL1SloadEnabled`.

### Upgrade window

Between the ecosystem upgrade and a chain's own upgrade, the new `ChainRegistrationSender` no longer pushes, and the
chain's v35 L2 still gates on its pushed mapping. So in that window:

- `allowInteropPeer`, `deregisterInteropPairs`, `suspendInterop` and `resumeInterop` change only L1, and don't
  reach chains not yet upgraded;
- a chain not yet upgraded still accepts the legs of a peer suspended meanwhile.

Governance therefore upgrades every interop chain in the same window as the ecosystem upgrade, and doesn't rely on
deregistration or suspension for a chain until it and its peers have upgraded.

## Governance procedure

### Suspending a chain

To stop interop to and from chain X, for example after a prover incident:

1. The `ChainRegistrationSender` owner calls `suspendInterop(X)` on L1.
2. Each chain stops sending to and accepting from X once it imports an anchor taken at or after that L1 block.
   - With an honest server, that is L1 finality (about 13 minutes) plus the server's import interval.
   - In any case, at most `L1_ANCHOR_MAX_LAG` of L2 block time after the last anchor the chain's operator imported
     before the suspension: an operator may still import a recorded anchor taken just before it, but reads stop once
     that one is stale.
   - L2 block time can trail L1 ([known issues](#known-issues)).
   - A chain in Priority Mode imports nothing, so its reads fail closed once its last anchor is stale.
3. Flows already in flight toward or from X stay unreceived ([K1](./interop-gating.md#k1-stuck-flows)) and complete
   after `resumeInterop(X)`.

Suspension doesn't touch X's whitelist or the pool, so `resumeInterop(X)` restores the previous state. During the
[upgrade window](#upgrade-window), chains not yet upgraded don't see it.

## Known issues

- **L2 clock.** Freshness is measured in L2 block time, which the operator chooses within the commit bounds: a batch's
  first block may trail L1 by up to `COMMIT_TIMESTAMP_NOT_OLDER` (3 days on mainnet, 30 days on testnets). A hostile
  operator can therefore serve gating reads from an anchor up to that much plus `L1_ANCHOR_MAX_LAG` old in L1 time.
  Bounding the first block's age for L1SLOAD chains is a follow-up.
- **Delay.** Every gating change (allowing, deregistering, suspending) reaches a chain only when it imports a newer
  anchor ([bounds](#suspending-a-chain)).
- **Priority Mode.** A chain in Priority Mode imports no anchors. Once its last anchor is older than
  `L1_ANCHOR_MAX_LAG`, every gating read on it reverts, so it neither sends nor accepts interop, and the atomic-flow
  refunds and finality on it (`AtomicFlowManager.authorizeRefund` and `requireFlowFinalized`, which read the
  [receive filter](./interop-gating.md#receive-filter)) wait until it leaves Priority Mode and imports an anchor again,
  even when sent as L1 transactions. This is deliberate: the alternative reads stale gating state, and a Priority Mode
  chain can't import the post-deadline roots that a timeout proof needs anyway.
- **No anchor, no interop.** A chain that never imported an anchor, or has the flag off, can neither send nor accept
  interop; its reads revert with `L1AnchorStale` or `L1SloadFailed`.
- **Storage layout is an ABI.** Moving `ChainRegistrationSender`'s gating mappings breaks every L2 reader.
