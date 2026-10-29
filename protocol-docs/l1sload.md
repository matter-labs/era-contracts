# L1SLOAD

From v36, L2 contracts on ZKsync OS chains settling on L1 read L1 storage through the `L1SLOAD` precompile at
`0x101` ([RIP-7728](https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7728.md)). Values are read at the chain's
**anchor**, an L1 block hash imported through the interop-root channel and checked on L1 at batch execution. ZKsync OS
verifies every value against that block's state root with a Merkle-Patricia proof.

Interop gating is the first user: chains read the peer whitelist, the peers' base tokens and suspensions from the L1
`ChainRegistrationSender` instead of having them pushed by service transactions. L1 becomes the only source of truth,
and governance can switch a chain's interop off with one L1 transaction.

## Safety argument

A batch whose L1 reads don't come from L1 can't be executed:

- **The anchor is a real L1 block.** At execution the Executor checks each imported anchor against
  `L1MessageRoot.recordedL1BlockHash`, which only L1 writes ([anchors](#anchors)). The anchor is part of the batch's
  dependency-roots rolling hash, which the proof commits to.
- **The values are that block's state.** ZKsync OS checks the header against the anchor hash and the account and
  storage proofs against its state root, inside the proven state transition. A missing or invalid witness never
  yields a value.
- **The anchor is recent.** Reads refuse an anchor older than `L1_ANCHOR_MAX_LAG` in L2 block time
  ([freshness](#freshness)).
- **Failures close.** With no anchor, a stale anchor or the [flag](#chain-config-flag) off, every gating read
  reverts, so the chain can neither send nor accept interop.

## Anchors

- **L1 record.** `L1MessageRoot.recordL1BlockHash()` stores `blockhash(block.number - 1)` with `block.timestamp`.
  It is permissionless and a no-op for an already recorded block. `commitBatches` of a chain with L1SLOAD on calls
  it, and the server's anchor keeper calls it when no chain commits. The record is permanent, so an anchor stays
  checkable after `blockhash` forgets the block.
- **Import on L2.** Anchors use the interop-root channel with the reserved id
  `L1_BLOCK_HASH_IMPORT_ID = uint256(keccak256("zksync.l1-block-hash-import")) - 1` (above the Bridgehub's
  `uint48` chain-id cap), the L1 block number, `sides = [blockHash]` and the recorded timestamp.
  `L2InteropRootStorage` requires the block to be newer than the current anchor (`L1AnchorNotNewer`) and writes the
  hash, number and timestamp to fixed slots that ZKsync OS reads. An anchor is not stored as a message root, so it
  can never prove a message.
- **Check on L1.** `Executor._verifyDependencyInteropRoots` takes an anchor's expected hash and timestamp from
  `recordedL1BlockHash(blockNumber)`, with the same checks as for message roots.

Anchors are checked against the L1 record, which a settlement layer doesn't have, so a chain with L1SLOAD on must
settle on L1.

## Freshness

A read is stale when `block.timestamp > anchorTimestamp + L1_ANCHOR_MAX_LAG` (1 hour), with the sum saturating
instead of overflowing. Both the precompile and `L1View` enforce it: the precompile fails the call (consuming the gas
passed to it), and `L1View` checks first and reverts with `L1AnchorStale`. A chain that never imported an anchor
reads nothing. A chain in Priority Mode imports no anchors, so its reads fail once the last anchor is stale.

## Reading L1 state

`L1Reads.l1sload` calls the precompile (input `l1Contract || key_1 || ... || key_k` with `1 <= k <= 5`, output `k`
words) with a low-level `staticcall`, since the precompile has no ABI; a failure reverts with `L1SloadFailed`. The
precompile also caps a transaction at 64 distinct `(anchor, address, key)` reads. Gating reads at most `1 + 4k` slots
for a transaction touching `k` other chains, so up to 15 chains always fit.

`L1View` reads `ChainRegistrationSender` with one precompile call per check:

| Check                          | Keys read                                                                            |
| ------------------------------ | ------------------------------------------------------------------------------------ |
| `isReceiveAllowed(self, peer)` | `interopPeerAllowed[self][peer]`, `interopSuspended[self]`, `interopSuspended[peer]` |
| `sendTarget(self, peer)`       | the three above, `interopPeerAllowed[peer][self]`, `interopBaseTokenAssetId[peer]`   |
| `baseTokenAssetId(chain)`      | `interopBaseTokenAssetId[chain]`                                                     |

The slots of these mappings (152, 153, 154) are an L2-facing ABI: they are pinned in `Config.sol` and by
`L1ViewStorageLayout.t.sol`, and an L1 upgrade must not move them. `interopEnabled` is not read:
`interopPeerAllowed[self][peer]` already implies both chains are enabled, and enabling is one-way.

## The base token snapshot

`allowInteropPeer(chainId, peer)` writes `interopBaseTokenAssetId[peer] = Bridgehub.baseTokenAssetId(peer)` after
checking that it is non-zero and that the peer has a batch in L1's message root. The Bridgehub never changes a chain's
base token, so the snapshot can't drift, and it is never deleted. A chain with a snapshot is "registered for interop":
`AtomicFlowManager` relies on it implying MessageRoot presence
({protocol-docs/atomicity/security.md#timeout-protocol-preconditions}), and `L2AssetRouter` takes a destination's base
token from it.

## Interop gating through L1 reads

The L2 Bridgehub reads `ChainRegistrationSender` at `l1ChainRegistrationSender()`, the unaliased
`chainRegistrationSender` stored at genesis.

- **Receive.** `isPeerAllowed(peer)` is this chain's allowance of the peer with neither chain suspended. It is the
  [receive filter](./interop-gating.md#receive-filter).
- **Send.** `interopSendTarget(peer)` requires both allowances and no suspension, and returns the peer's snapshot.
  `InteropCenter` reverts with `DestinationChainNotRegistered` without a snapshot and `DestinationChainNotAllowed`
  otherwise, so a one-sided whitelist can't start a flow ([K1](./interop-gating.md#k1-stuck-flows)).
- **Suspension.** `suspendInterop` / `resumeInterop` (owner only) switch a chain off and on in both directions for
  every chain at once. They touch neither the whitelist, the snapshots nor `interopEnabled`.
- **No push.** `allowInteropPeer` and `deregisterInteropPairs` only write L1. The service transactions, the
  `bridgehubDeposit` resubmission and the L2 Bridgehub's push entry points are gone. The L2 mapping's slot is kept as
  `__DEPRECATED_isPeerAllowed`.

## Chain config flag

The precompile is enabled per chain by the `l1sload_enabled` chain-config word
({protocol-docs/chain-config.md#l1sload}). With it off, `0x101` behaves like an empty account. Since gating depends
on it, `enableInterop` requires the flag (`L1SloadNotEnabled`), and the flag can't be turned off while interop is
enabled (`L1SloadRequiredByInterop`).

## Upgrade from v35

- **Snapshots.** v35 kept none. The `ChainRegistrationSender` upgrade calls `initializeUpgrade()`
  (`reinitializer(2)`, proxy admin only), which snapshots every chain with interop enabled and a batch in the message
  root. That covers every peer a v35 admin could have allowed.
- **The flag.** `DefaultUpgrade` turns the flag on for a chain on L1 whose interop is enabled, so no chain crosses
  with interop on and L1SLOAD off.
- **First anchor.** None is seeded. Until the chain imports its first anchor, its gating reads revert and interop
  pauses.
- `enableInterop` reverts with `ChainPredatesL1Sload` for a chain still on pre-v36 facets.

### Upgrade window

Between the ecosystem upgrade and a chain's own upgrade, the new `ChainRegistrationSender` no longer pushes while the
chain's v35 L2 still gates on its pushed mapping. Allowances, deregistrations and suspensions made then don't reach
chains not yet upgraded, so governance upgrades every interop chain in the same window as the ecosystem.

## Suspending a chain

1. The `ChainRegistrationSender` owner calls `suspendInterop(X)` on L1.
2. Every chain refuses X once it imports an anchor taken after that block. With an honest server this takes the
   next L1 record, L1 finality and the import interval: under an hour on an idle ecosystem. Against any operator,
   reads at an older anchor stop `L1_ANCHOR_MAX_LAG` after the suspension in L2 block time.
3. Flows in flight to or from X stay unreceived ([K1](./interop-gating.md#k1-stuck-flows)) and complete after
   `resumeInterop(X)`.

## Known issues

- **L2 clock.** Freshness is measured in L2 block time, which may trail L1 by up to `COMMIT_TIMESTAMP_NOT_OLDER`
  (3 days on mainnet). Bounding it for L1SLOAD chains is a follow-up.
- **Priority Mode.** Gating reads, and so atomic-flow refunds and finality for legs from other chains, wait until the
  chain leaves Priority Mode and imports an anchor again.
