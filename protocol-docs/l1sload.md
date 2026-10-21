# L1SLOAD-lite (proof of concept)

L2 contracts read L1 storage at an **anchored L1 block** through the ZKsync OS `L1SLOAD` precompile. The anchor
is an L1 block hash that the operator imports through the existing interop-root channel and that L1 checks at
batch execution, like every imported root. With it, L1 is the single source of truth for interop gating: chains
read the whitelist, the peers' base tokens and the suspensions from `ChainRegistrationSender` instead of having
them pushed by service transactions.

## Anchors

- **Reserved id.** Anchors are imported through the interop-root channel with `chainId = L1_BLOCK_HASH_IMPORT_ID =
uint256(keccak256("zksync.l1-block-hash-import")) - 1`, `blockOrBatchNumber` = the L1 block number, `sides =
[blockHash]` and `timestamp` = the time L1 recorded the hash. No chain can have this id: the Bridgehub caps chain
  IDs at `type(uint48).max`.
- **L1 record.** `L1MessageRoot.recordL1BlockHash()` is permissionless. It stores
  `blockhash(block.number - 1)` with `block.timestamp` under `block.number - 1`, and `recordedL1BlockHash(n)`
  returns it. The record is permanent, so an anchor stays verifiable at execution however long ago it was taken;
  the EVM's `blockhash` only reaches 256 blocks back.
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

`l1AnchorTimestamp + L1_ANCHOR_MAX_LAG >= batch's last L2 block timestamp`,

where `l1AnchorTimestamp` includes the anchors the batch itself imports. Otherwise execution reverts with
`L1AnchorTooOld`, so an operator can't serve L1 reads from an arbitrarily old L1 state. The executor keeps the
maximum, without relying on L2 importing anchors in increasing order. The rule doesn't apply:

- to chains that never imported an anchor;
- in Priority Mode, whose batches can't contain the service transaction that imports anchors. L1 reads there see
  the last anchor, however old.

## Reading L1 state

`L1Reads.l1sload` wraps the precompile (input `l1Contract || key_1 || ... || key_k`, `1 <= k <= 5`, output `k`
words). `L1View` reads only `ChainRegistrationSender`, with one precompile call per check:

| Check                          | Keys read                                                                                                |
| ------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `isReceiveAllowed(self, peer)` | `interopPeerAllowed[self][peer]`, `interopSuspended[self]`, `interopSuspended[peer]`                     |
| `sendTarget(self, peer)`       | the three above, `interopPeerAllowed[peer][self]` and `interopBaseTokenAssetId[peer]` (the maximum of 5) |
| `isRegistered(chain)`          | `interopBaseTokenAssetId[chain]`                                                                         |

The slots of these mappings in the implementation layout (152, 153, 154) become an L2-facing ABI: an L1 upgrade
that moves them silently breaks every L2 reader. They are pinned in `Config.sol` and by `L1ViewStorageLayout.t.sol`,
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
- **It is the interop registration.** A chain "is registered for interop" when it has a snapshot, i.e. some admin
  allowed it as a peer. The leaf-count check is what makes a snapshot imply MessageRoot presence, which
  `AtomicFlowManager.append` relies on for every co-leg's source chain
  ({protocol-docs/atomicity/security.md#timeout-protocol-preconditions}); it reads it with
  `L2Bridgehub.interopBaseTokenAssetId`.

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
- **No push.** `allowInteropPeer` and `deregisterInteropPairs` only write L1 state; the service transactions,
  `bridgehubDeposit` resubmission and the L2 Bridgehub's `allowInteropPeer` / `deregisterChainForInterop` are gone.
  The mirrored mapping's slot is kept as `__DEPRECATED_isPeerAllowed`. Entries the push wrote into the L2
  Bridgehub's `baseTokenAssetId` stay, but no gating reads them.

## Proof-of-concept shortcuts

- The batch's last L2 block timestamp is recorded at commit in `batchLastBlockTimestamp`. Production would carry it
  in `StoredBatchInfo.timestamp`, which ZKsync OS commits as zero.
- The L2 batch timestamp is chosen by the operator within the commit bounds (up to `COMMIT_TIMESTAMP_NOT_OLDER` in
  the past), so the freshness rule bounds the anchor's age relative to the batch, not to L1's clock at execution.
- Every gating change (allowing, deregistering, suspending) takes effect on L2 once a newer anchor is imported, up
  to `L1_ANCHOR_MAX_LAG` later, and never in Priority Mode.
- Every gating read needs an anchor: a chain that never imported one can neither send nor accept interop.
- The anvil-interop harness has no `L1SLOAD`, so its interop specs need a shim before they can run on this branch.
