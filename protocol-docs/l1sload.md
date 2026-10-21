# L1SLOAD-lite (proof of concept)

L2 contracts read L1 storage at an **anchored L1 block** through the ZKsync OS `L1SLOAD` precompile. The anchor
is an L1 block hash that the operator imports through the existing interop-root channel and that L1 checks at
batch execution, like every other imported root.

## Anchors

- **Reserved id.** Anchors are imported as interop roots with `chainId = L1_BLOCK_HASH_IMPORT_ID =
uint256(keccak256("zksync.l1-block-hash-import")) - 1`, `blockOrBatchNumber` = the L1 block number, `sides =
[blockHash]` and `timestamp` = the time L1 recorded the hash. No chain can have this id: the Bridgehub caps chain
  IDs at `type(uint48).max`.
- **L1 record.** `L1MessageRoot.recordL1BlockHash()` is permissionless. It stores
  `blockhash(block.number - 1)` with `block.timestamp` under `block.number - 1`, and `recordedL1BlockHash(n)`
  returns it. The record is permanent, so an anchor stays verifiable at execution however long ago it was taken;
  the EVM's `blockhash` only reaches 256 blocks back.
- **Import on L2.** `L2InteropRootStorage` stores the anchor like any root and emits `InteropRootAdded` with exactly
  one side, the block hash, so the ZKsync OS event hook folds it into the batch's dependency-roots rolling hash. If
  the block is newer than the current anchor, it also writes the anchor's hash and number to the fixed slots
  `keccak256("zksync-os.l1sload.anchor.block-hash")` and `keccak256("zksync-os.l1sload.anchor.block-number")`,
  where ZKsync OS reads it. The anchor never moves backwards. `L1SLOAD` reverts while no anchor is set.
- **Check on L1.** `Executor._verifyDependencyInteropRoots` takes the expected root and timestamp of an anchor from
  `recordedL1BlockHash(blockNumber)`, with the same checks as for message roots
  ({protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}).
- **Not a message root.** Since anchors are stored as ordinary roots, `L2MessageVerification` refuses the reserved
  id, so a block hash can never prove a message.

## Freshness

Each chain tracks the newest anchor timestamp it imported (`l1AnchorTimestamp`, monotonic). Once a chain has
imported an anchor, every batch it executes must satisfy

`l1AnchorTimestamp + L1_ANCHOR_MAX_LAG >= batch's last L2 block timestamp`,

where `l1AnchorTimestamp` includes the anchors the batch itself imports. Otherwise execution reverts with
`L1AnchorTooOld`, so an operator can't serve L1 reads from an arbitrarily old L1 state. The rule doesn't apply:

- to chains that never imported an anchor;
- in Priority Mode, whose batches can't contain the service transaction that imports anchors. L1 reads there see
  the last anchor, however old.

## Reading L1 state

`L1Reads.l1sload` wraps the precompile (input `l1Contract || key_1 || ... || key_k`, `1 <= k <= 5`, output `k`
words). `L1View` computes the slots of the L1 state L2 contracts read:

| L1 contract (implementation layout) | Variable                                   |
| ----------------------------------- | ------------------------------------------ |
| `L1MessageRoot`                     | `interopEnabled[chainId]`                  |
| `L1MessageRoot`                     | `interopSuspended[chainId]`                |
| `ChainRegistrationSender`           | `interopPeerAllowed[chainId][peerChainId]` |

These slots become an L2-facing ABI: an L1 upgrade that moves them silently breaks every L2 reader. They are
pinned in `Config.sol` and by tests that write through the real L1 contracts and read the computed slots back.

## Interop gating through L1 reads

`L1MessageRoot.suspendInterop(chainId)` / `resumeInterop(chainId)` (Bridgehub owner) switch a chain off and on
again without touching `interopEnabled`, which the vault's pool accounting keys on
({protocol-docs/interop-gating.md#interop-pool}). A chain is **active** while it is enabled and not suspended.

Once the Bridgehub owner sets `L2Bridgehub.setL1ReadAddresses(l1MessageRoot, l1ChainRegistrationSender)`:

- `isPeerAllowed(peer)` is `active(self) && active(peer) && interopPeerAllowed[self][peer]`, read from L1. It is
  the [receive filter](./interop-gating.md#receive-filter), so suspending a chain on L1 stops every peer from
  accepting its interop with one L1 transaction, without service transactions.
- `canSendTo(peer)` additionally requires `interopPeerAllowed[peer][self]`. `InteropCenter` sends only to such
  peers, so a one-sided whitelist can't start a flow ([K1](./interop-gating.md#k1-stuck-flows)).

Until the addresses are set, both fall back to the whitelist mirrored by service transactions, which holds only the
chain's own side.

## Proof-of-concept shortcuts

- The batch's last L2 block timestamp is recorded at commit in `batchLastBlockTimestamp`. Production would carry it
  in `StoredBatchInfo.timestamp`, which ZKsync OS commits as zero.
- The L1 addresses are set by the owner. Production would pass them in the force deployments.
- The L2 batch timestamp is chosen by the operator within the commit bounds (up to `COMMIT_TIMESTAMP_NOT_OLDER` in
  the past), so the freshness rule bounds the anchor's age relative to the batch, not to L1's clock at execution.
- Suspension is read at the anchor: it takes effect on L2 once a newer anchor is imported, up to
  `L1_ANCHOR_MAX_LAG` later, and never in Priority Mode.
