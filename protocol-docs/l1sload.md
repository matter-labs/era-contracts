# L1SLOAD

From v36, ZKsync OS chains settling on L1 can read L1 storage through the `L1SLOAD` precompile at `0x101`
([RIP-7728](https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7728.md)). Only an explicit ZKsync OS allowlist of
system contracts can call it (v36: `L2Bridgehub`), and priority and upgrade transactions never read L1. Values are read
at the chain's **anchor**: an L1 block hash imported through the interop-root channel and checked on L1 when the batch
executes. ZKsync OS verifies each value against that block's state root with a Merkle-Patricia proof, inside the proven
state transition.

## Anchors

- **Record on L1.** `L1MessageRoot.recordL1BlockHash()` stores `blockhash(block.number - 1)` with `block.timestamp`.
  The record is permanent, so an anchor stays checkable after `blockhash` forgets the block. It is permissionless and
  does nothing for a block already recorded.
- **Recording at commit.** `commitBatchesSharedBridge` of a chain with interop enabled records an anchor at most once
  per `L1_ANCHOR_RECORD_INTERVAL` (5 minutes), since a record costs about 70k gas. The chain's
  `lastL1AnchorCheckTimestamp` holds when a commit last checked, whether or not it recorded, so a chain without interop
  pays for the check at most once per interval too. Anyone can record when no chain commits, for example an
  ecosystem keeper.
- **Import on L2.** The server imports an anchor as an interop root with the reserved id
  `L1_BLOCK_HASH_IMPORT_ID = uint256(keccak256("zksync.l1-block-hash-import")) - 1` (above the Bridgehub's `uint48`
  chain-id cap), the L1 block number, `sides = [blockHash]` and the recorded timestamp. `L2InteropRootStorage` moves
  the anchor only to a newer block: it writes the block number, hash and timestamp to the fixed slots
  `bytes32(uint256(keccak256("zksync.l2-interop-root-storage.l1-anchor-<field>")) - 1)` (`L1SLOAD_ANCHOR_*_SLOT`),
  and emits `L1AnchorImported`. ZKsync OS reads the hash and timestamp slots, so they are consensus-critical; the
  block number is read only by contracts. An import that isn't newer leaves the anchor as it is, so an anchor import
  never reverts. An anchor is not stored as a message root, so it can't prove a message.
- **Dependency roots.** Every anchor import, newer or not, emits `InteropRootAdded`. ZKsync OS adds the root to the
  batch's dependency-roots rolling hash from that event, and the server sends the execute call every root the
  import transaction carried, so the two agree and every imported anchor is checked on L1.
- **Check on L1.** `Executor._verifyDependencyInteropRoots` takes an anchor's expected hash and timestamp from
  `recordedL1BlockHash(blockNumber)`, with the same checks as for message roots. A batch that imported an unrecorded
  or altered anchor can't execute.

The upgrade to v36 seeds no anchor: a chain's reads fail until it imports its first one.

## Freshness

The precompile refuses an anchor older than `L1SLOAD_MAX_ANCHOR_AGE` (1 hour): a read fails when
`block.timestamp > anchorTimestamp + L1SLOAD_MAX_ANCHOR_AGE`, with the sum saturating instead of overflowing, and when
there is no anchor. The age is measured from the L1 time the anchor was recorded to the L2 block's timestamp, so an
anchor recorded after the L2 block's timestamp counts as fresh. A consumer that needs a tighter bound calls
`L1Reads.requireFresh(maxAge)`, which applies the same rule with its own `maxAge` and reverts with `L1AnchorStale`.

- **L2 clock.** L2 block time may trail L1 by up to `COMMIT_TIMESTAMP_NOT_OLDER` (3 days on mainnet), so freshness
  bounds the anchor's age on the L2 clock, not in wall-clock time.
- **Priority Mode.** A chain in Priority Mode imports no anchors, so its reads fail once the last anchor is stale.

## Reading L1 state

`L1Reads` wraps the precompile:

- `anchor()` returns the anchor's block number, hash and timestamp.
- `read(l1Contract, key)` and `read(l1Contract, keys)` call the precompile with a low-level `staticcall`, since it has
  no ABI: the input is `l1Contract || key_1 || ... || key_k` with `1 <= k <= L1SLOAD_MAX_KEYS` (5), and the output the
  `k` values. A failed call reverts with `L1SloadFailed`.
- The precompile consumes all the gas passed to a failed call, so `read` forwards `L1SLOAD_CALL_GAS` (50,000): more
  than a successful call costs (`2000 + 2000 * k` per RIP-7728, plus its two reads of the anchor slots), and the most
  a failed call can cost.
- `mappingSlot(slot, key)` returns the slot Solidity stores `mapping[key]` at for a mapping declared at `slot`; nested
  mappings chain it.

The L1 slots a contract reads are an L2-facing ABI: an L1 upgrade must not move them.

## Settling on L1

Anchors are checked against `L1MessageRoot`'s record, which a settlement layer doesn't have, so L1SLOAD needs the chain
to settle on L1:

- the Committer records anchors only on L1;
- the Executor reverts with `L1AnchorNotSupportedOnGateway` on an anchor in a batch it executes on a settlement layer;
- `L1ChainAssetHandler` refuses to migrate a chain with interop enabled off L1 (`InteropChainCannotMigrate`).
