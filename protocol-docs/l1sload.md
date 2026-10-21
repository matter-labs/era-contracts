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
- **The anchor is recent.** The [freshness rule](#freshness) bounds how far behind L1 the anchor can be at a batch,
  outside Priority Mode.
- **Failures close.** With no anchor or with the [flag](#chain-config-flag) off, every read reverts
  (`L1SloadFailed`): the chain can neither send interop nor accept it.

The storage slots of the gating mappings are an L2-facing ABI ([reading L1 state](#reading-l1-state)).

## Anchors

- **Reserved id.** Anchors are imported through the interop-root channel with `chainId = L1_BLOCK_HASH_IMPORT_ID =
uint256(keccak256("zksync.l1-block-hash-import")) - 1`, `blockOrBatchNumber` = the L1 block number, `sides =
[blockHash]` and `timestamp` = the time L1 recorded the hash. No chain can have this id: the Bridgehub caps chain
  IDs at `type(uint48).max`.
- **L1 record.** `L1MessageRoot.recordL1BlockHash()` stores `blockhash(block.number - 1)` with `block.timestamp`
  under `block.number - 1`, emits `L1BlockHashRecorded`, and `recordedL1BlockHash(n)` returns it. Every
  `commitBatches` on L1 calls it, so operators send no transaction for it. Commits don't wait for proofs, so a
  prover outage doesn't stop new anchors; recording at execute would have paused the L2 after `L1_ANCHOR_MAX_LAG`
  without proofs. It stays permissionless, and is a no-op when the block is already recorded, so the chains
  committing in one L1 block share one record. When production is paused waiting for an anchor there are no
  commits, so the server's keeper calls it itself. The record is permanent, so an anchor stays verifiable at
  execution however long ago it was taken; the EVM's `blockhash` only reaches 256 blocks back.
- **Import on L2.** `L2InteropRootStorage` runs the checks of every import (one non-zero side, non-zero
  timestamp), then requires the block to be newer than the current anchor (`L1AnchorNotNewer`), so the anchor
  only moves forward and block 0 can't be anchored. It writes the anchor's hash and number to the fixed slots
  `keccak256("zksync-os.l1sload.anchor.block-hash")` and `keccak256("zksync-os.l1sload.anchor.block-number")`,
  where ZKsync OS reads it, and emits `InteropRootAdded` with exactly one side, the block hash, so the ZKsync OS
  event hook folds it into the batch's dependency-roots rolling hash. The anchor is stored only there: neither
  `interopRoots` nor `latestInteropRootTimestamp` record it. `L1SLOAD` reverts while no anchor is set.
- **Check on L1.** `Executor._verifyDependencyInteropRoots` takes the expected root and timestamp of an anchor from
  `recordedL1BlockHash(blockNumber)`, with the same checks as for message roots
  ({protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}).
- **Not a message root.** `interopRoots(L1_BLOCK_HASH_IMPORT_ID, n)` stays zero, so `L2MessageVerification`'s
  non-zero root check rejects every proof against an anchor: a block hash can never prove a message.

## Freshness

Each chain tracks the newest anchor timestamp it imported (`l1AnchorTimestamp`, monotonic). Once a chain has
imported an anchor, every batch it executes must satisfy

`l1AnchorTimestamp + L1_ANCHOR_MAX_LAG >= StoredBatchInfo.timestamp`,

where `l1AnchorTimestamp` includes the anchors the batch itself imports and `L1_ANCHOR_MAX_LAG` is 1 hour. Otherwise
execution reverts with `L1AnchorTooOld`, so an operator can't serve L1 reads from an arbitrarily old L1 state. The
executor keeps the maximum, without relying on L2 importing anchors in increasing order.

`StoredBatchInfo.timestamp` is the batch's last L2 block timestamp. ZKsync OS batches stored 0 there until v36; from
v36 the Committer stores `lastBlockTimestamp`, which the batch output hash, and so the proof, commits to. It does so
for every batch it commits, with no per-batch version gate. The server's `StoredBatchInfo` encoding gates on the
batch's protocol version (≥ v36) instead, and the two agree: after a chain upgrade with an L2 upgrade transaction the
first batch committed must be the upgrade batch (`Committer._commitBatches`, `processSystemUpgradeTx`). The rule
doesn't apply:

- to chains that never imported an anchor;
- to batches committed before v36, whose timestamp is 0. The upgrade engines execute every committed batch before a
  chain upgrades, so this is a defensive skip;
- in Priority Mode, whose batches can't contain the service transaction that imports anchors. L1 reads there see
  the last anchor, however old.

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
- **The first anchor.** The upgrade seeds no anchor: a seeded one would be an unchecked L1 state. The first
  `commitBatches` after the upgrade records one, and the operator imports it in a later batch. Until then the
  chain's interop reads revert, so its interop pauses for about one batch.
- **Stale L2 state.** The L2 Bridgehub's v35 whitelist stays under `__DEPRECATED_isPeerAllowed`, and its
  `baseTokenAssetId` entries for peers stay but are not read for gating.
- **Batch timestamps.** Batches committed before the upgrade keep `StoredBatchInfo.timestamp = 0`, and the
  [freshness rule](#freshness) skips them. The server encodes the new value for batches committed from v36.

## Governance procedure

### Suspending a chain

To stop interop to and from chain X, for example after a prover incident:

1. The `ChainRegistrationSender` owner calls `suspendInterop(X)` on L1.
2. Each chain stops sending to and accepting from X once it imports an anchor taken at or after that L1 block.
   Outside Priority Mode the freshness rule makes that happen within `L1_ANCHOR_MAX_LAG` of its batches' timestamps.
3. Flows already in flight toward or from X stay unreceived ([K1](./interop-gating.md#k1-stuck-flows)) and complete
   after `resumeInterop(X)`.

Suspension doesn't touch X's whitelist or the pool, so `resumeInterop(X)` restores the previous state.

## Known issues

- **Batch-relative freshness.** The L2 batch timestamp is chosen by the operator within the commit bounds (up to
  `COMMIT_TIMESTAMP_NOT_OLDER` in the past), so the freshness rule bounds the anchor's age relative to the batch, not
  to L1's clock at execution. Tightening that bound for interop chains is a follow-up.
- **Delay.** Every gating change (allowing, deregistering, suspending) reaches a chain only when it imports a newer
  anchor, and never in Priority Mode.
- **No anchor, no interop.** A chain that never imported an anchor, or has the flag off, can neither send nor accept
  interop; its reads revert with `L1SloadFailed`.
- **Storage layout is an ABI.** Moving `ChainRegistrationSender`'s gating mappings breaks every L2 reader.
