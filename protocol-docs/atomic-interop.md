# Atomic interop without L1 coordination

This module (`l1-contracts/contracts/atomic-interop/`) makes a multi-leg interop flow **atomic** — every leg executes or none does — **without a
central L1 coordinator**. It rides on the normal interop bundle path (`InteropCenter.sendBundle` ->
`L2AssetRouter` -> `InteropHandler.executeAtomicBundle`); the only addition is an **Indexed Merkle
Tree (IMT)** per chain that records each leg's commitment, plus per-leg **IMT proofs** authenticated
against the regular **interop-root channel**: the ZKsync OS bootloader snapshots each chain's IMT root
at every batch boundary and commits both snapshots as dedicated leaves of the batch's **chain batch
root** (`ChainBatchRootTree`: leaf 2 = batch begin, leaf 3 = batch end), which settles and is
re-imported on every chain. There is no extra L1 contract, no global-root registry, and no L2->L1
message — finality is proven, not dispatched.

## Key values

- `bundleHash = keccak256(abi.encode(sourceChainId, bundleBytes))` — a leg's bundle, chain-specific.
- `flowId = keccak256(abi.encode(preimage))` —
  binds all legs, each leg's source chain, the deadline, and the settlement layer. `legBundleHashes` is
  strictly ascending (canonical order + dedup); `legSourceChainIds` is positional (aligned 1:1, may
  repeat); `deadline` is a settlement-layer timestamp.
- `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))` — the IMT
  leaf value for a leg. It bakes in `flowId` (hence all legs) and the chain-specific `bundleHash`, so a
  leg's commit value can only ever be inserted into its own source chain's IMT.

The atomic-send parameters (the full `flowId` **preimage** — `deadline`, `settlementLayerChainId`,
`legBundleHashes`, `legSourceChainIds` — plus `lowNullifierIndex`) travel out-of-band as the ERC-7786
`atomicBundle((uint64,uint256,bytes32[],uint256[]),uint256)` bundle attribute — deliberately **not**
part of the bundle, so `bundleHash` does not depend on the preimage (which would be circular: the
preimage's leg hashes include the bundle's own hash). The attribute carries the preimage rather than
an opaque `flowId` so that `AtomicFlowManager.append` can recompute the id on-chain and verify the
sent bundle is actually one of the flow's legs (declared with the sending chain as its source), and
that every other leg declares a Bridgehub-registered source chain (registration guarantees MessageRoot
presence, which the refund path's absence proof needs) — a wrong or stale preimage, or one naming an
unprovable source chain, reverts the send instead of committing a leg that could neither finalize nor
be refunded. The registration check also rejects L1 as a declared leg source (L1 is never registered
as an interop chain), matching the send-side rule that interop bundles cannot be initiated on L1.

## Flow

1. **Atomic send** (each leg, on its source chain). The user calls `InteropCenter.sendBundle` with the
   `atomicBundle` attribute. The source burn flows through the normal `initiateIndirectCall` /
   `L2AssetRouter` path; instead of publishing the bundle to L1, the InteropCenter calls
   `AtomicFlowManager.append`, which first recomputes `flowId` from the attribute's preimage and
   validates it (canonical shape, L1 settlement layer, this bundle is a leg with this chain as its
   source, co-leg source chains registered) — any violation reverts the whole send, burn included —
   and then inserts `commitValue` into this chain's `L2InteropCommitmentTree`
   (an append-only **indexed** Merkle tree; leaves carry `{value, nextIndex, nextValue}` so both
   membership and non-membership are provable in O(log n)). The leg's local state becomes `Committed`.
2. **Root settlement + import.** The bootloader reads the tree's root directly from storage at every
   batch boundary and commits both snapshots into the batch's chain batch root (leaf 2 = begin, leaf 3
   = end; see `l1-contracts/contracts/common/libraries/ChainBatchRootTree.sol`). The chain batch root settles into the
   settlement layer's `MessageRoot` and is re-imported into every chain's `L2InteropRootStorage`
   through the standard interop-root channel — the same channel used for all interop, built on both L1
   and the gateway, so it works for L1-settling chains too.
   Data availability: atomic-interop chains use the `L2_TO_L1_ONLY` DA scheme
   (`CalldataL1DAValidatorZKsyncOS`), which publishes only the L2->L1 region as permanent L1 calldata —
   enough to keep the IMT contents reconstructible from L1 data alone.
3. **Finalize** (destination). `InteropHandler.executeAtomicBundle(bundle, finalityProof)` calls
   `AtomicFlowManager.requireFlowFinalized`, which for **every** leg verifies an IMT **inclusion** proof
   (`AtomicInteropProof.verifyInclusion`): the leg's `commitValue` is present in its source chain's
   **batch-end** IMT root (chain-batch-root leaf 3, authenticated with an exact-depth 3-sibling path)
   of a batch that settled no later than the deadline (`l1Timestamp <= deadline`; a batch's inclusion
   time only ever rises, so a commit cannot be back-dated to look in-time after the fact) on the flow's
   `settlementLayerChainId`, and the proof's `sourceChainId` matches the
   leg's declared `legSourceChainIds[i]`. If all legs are proven committed in time, the bundle's calls
   execute (the destination mint). A `commitValue` can only exist in its true source chain's tree, so
   inclusion is self-binding; non-inclusion is not, which is why the source chain is checked explicitly.
4. **Timeout / refund.** If a leg never commits in time, `AtomicFlowManager.authorizeRefund` takes a
   single absence proof (`AtomicInteropProof.verifyTimeoutAbsence`): anchored on an aggregated root
   created strictly after the deadline (the imported root's creation timestamp, double checked on the
   settlement layer during batch execution), the missing leg's `commitValue` is proven absent from
   the batch-begin IMT root of a late batch — or, for a source chain that **halts** and never settles
   a post-deadline batch, from the batch-end IMT root of the chain's **last batch inside the anchor
   root**. The exact conditions, and why they are mutually exclusive with finalization yet always
   satisfiable for a genuinely timed-out leg, are described in the `AtomicInteropProof` library
   header.
   The proof is bound to the missing leg's source chain and settlement layer. It
   marks this chain's `Committed` legs `Revertable`; `claimRefund` then reverses each burn by asking the
   call's local sender (`InteropCall.from`) to recover itself via `IAtomicRecoverable.recoverAtomicCall`
   (implemented by `L2AssetRouter`, whose burn path produced the call), re-minting to the original
   depositor. Recovery is **best-effort**: only burn-produced (asset-router) calls are recovered; direct
   calls move no funds at send, have nothing to reverse, and are skipped (their `from` — possibly an
   EOA — need not implement the interface); the refund succeeds as long as at least one call recovered.
   Consequently the protocol does not guarantee full refundability of an arbitrary bundle — making a
   fund-moving leg recoverable (an asset-router deposit) is the flow author's responsibility. Atomic
   sends reject only native-`value` legs (which can never be reversed) and L1 destinations (an atomic
   bundle is never published to L1 and could only ever time out — but L2->L1 withdrawals must never be
   revertable, see `L2AssetTracker`).

Leg state machine (`LegState`): `Unset -> Committed` (send) `-> Revertable -> Reverted` (timeout path).

## Timeout-protocol preconditions

The timeout proof relies on three preconditions, each enforced on chain:

1. **Every chain interop can target has at least one batch inside the settlement layer's message
   root.** Enforced at two points:
   - Freshly created chains report their genesis batch root right after registration, in the same
     `createNewChain` transaction: the chain's DiamondInit stores
     `ChainBatchRootTree.genesisChainBatchRoot()` (batch 0 has no logs and a freshly seeded IMT, so
     the value is exact) as the batch-0 `l2LogsRootHash`, and the Bridgehub calls
     `MessageRoot.seedGenesisRoot`, which pulls it from the chain's getters (once-only, fresh
     ZKsync OS chains only).
   - Already-deployed chains onboarded with a non-zero starting batch number are NOT seeded (a real
     batch with that number exists elsewhere, and a synthetic leaf would diverge from it); instead
     `ChainRegistrationSender` refuses to register a chain for interop until it has settled at least
     one batch into the message root (`MessageRoot.chainTreeLeafCount > 0`).
     This guarantees the "last batch inside the aggregated root" required by the in-time timeout
     branch always exists, even for a chain that halts before settling anything.
     Settlement-layer migration registers the chain on the new layer's message root with an empty
     tree; this is acceptable under the current assumption that only the **L1** message root anchors
     timeout proofs (see the `IMPORTANT` note in `ChainAssetHandlerBase._bridgeMint`).
2. **Interop only involves registered chains.** An unregistered chain has no chain-id leaf in the
   settlement layer's aggregated shared tree (`MessageRootBase.sharedTree`), so no proof — neither
   finality nor timeout — can be verified against it at all: every proof path terminates in the
   chain's chain-id leaf inside an imported aggregation root. Interop towards a chain must therefore
   only be enabled once the chain is registered (has its `sharedTree` leaf) AND has a batch in its
   chain tree (precondition 1) — which is exactly what the `ChainRegistrationSender` gate checks.
3. **Every batch leaf carries the timestamp at which it entered the shared root.** Enforced by
   `MessageRoot.addChainBatchRootV32`, which folds the settlement-layer `block.timestamp` into the
   batch leaf (`MessageHashing.batchLeafHash`); the timestamp is therefore proven by the same
   inclusion proof that authenticates the IMT root. Aggregated roots additionally carry their own
   creation timestamp — one `(blockNumber, root, timestamp)` tuple, exposed by
   `MessageRoot.historicalRoot` on the settlement layer, imported into
   `L2InteropRootStorage.interopRoots` and double checked at batch execution — which anchors the
   "root from after the deadline" requirement.

## Contracts

| Contract                                                                                  | Layer | Role                                                                                                                                                                                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `L2InteropCommitmentTree`                                                                 | L2    | Per-chain append-only **Indexed** Merkle Tree (`{value, nextIndex, nextValue}` leaves). `insert` is appender-gated (the flow manager). Publishes nothing: the bootloader reads the root straight from its (consensus-critical) storage at batch boundaries. Built-in at `0x10012`.                                                              |
| `AtomicFlowManager`                                                                       | L2    | `append` (from `InteropCenter`), `requireFlowFinalized` (from `InteropHandler`), `authorizeRefund` / `claimRefund` (timeout). Holds per-leg `LegState`. Built-in at `0x10014`.                                                                                                                                                                  |
| `libraries/AtomicInteropProof`                                                            | L2    | `verifyInclusion` and `verifyTimeoutAbsence` (for inclusion and timeout proofs respectively), `commitValue`, and the private `_authenticateRoot` — authenticates a `chainImtRoot` as a chain-batch-root leaf (2 = begin / 3 = end, exact depth) against the imported interop root and derives the batch's `l1Timestamp` for the deadline check. |
| `IL2InteropCommitmentTree`, `IAtomicFlowManager`, `IAtomicInterop`, `AtomicInteropErrors` | L2    | Interfaces, shared structs (`ImtProof`, `AtomicFlow`, `AtomicFlowPreimage`, `AtomicFinalityProof`, `LegState`), and errors.                                                                                                                                                                                                                     |

The flow's entry points live outside this directory: `InteropCenter` (`l1-contracts/contracts/interop/`, `0x1000d`) drives the
send + `append`; `InteropHandler` (`l1-contracts/contracts/interop/`, `0x1000e`) drives `executeAtomicBundle`; `L2AssetRouter`
(`l1-contracts/contracts/bridge/asset-router/`, `0x10003`) does the burn / mint and implements `IAtomicRecoverable.recoverAtomicCall`
for the timeout recovery, recognising the flow manager by its canonical address. The underlying IMT data structure is `l1-contracts/contracts/common/libraries/IndexedMerkleTree.sol`.

> Address `0x10013` is intentionally reserved/empty — it formerly held a global-root importer that was
> removed when atomic interop moved to the interop-root channel.

## ZKsync OS genesis

The two L2 contracts are predeployed in the ZKsync OS genesis (settlement-layer support lives in the
core protocol: the `Executor` pushes batch roots via `addChainBatchRootV32`, verifies imported
dependency roots; the genesis batch leaf is seeded by `MessageRoot.seedGenesisRoot`):

- registered in the genesis gen tool (`tools/zksync-os-genesis-gen`) at `0x10012`
  (`L2InteropCommitmentTree`) and `0x10014` (`AtomicFlowManager`) — constants in
  `l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol`;
- seeded during genesis in `L2GenesisForceDeploymentsHelper._initializeV31Contracts` (ZKsync OS only):
  the commitment tree's `initL2` seeds the IMT and the manager's `initL2` records the
  L1 chain id every flow's settlement layer is checked against. No further wiring is needed —
  every collaborator is referenced by its canonical fixed address: the tree's appender and the manager's
  tree / interop center / interop handler are constant getters, and the AR recognises the manager via
  `_atomicFlowManagerAddr()`. The manager no longer holds an asset-router reference at all — it drives
  recovery generically through `IAtomicRecoverable` on each bundle call's target.

## Off-chain tooling (`l1-contracts/test/anvil-interop/`)

- `src/helpers/imt-engine-lib.ts` — the off-chain IMT engine: commit values, the
  low-nullifier index for an insert, and the O(log n) inclusion / non-inclusion proofs (must match
  `IndexedMerkleTree` bit-for-bit), plus the settlement-proof byte builder (metadata header, the 3-hop
  chain-batch-root leaf path, `l1Timestamp`).
- `test/hardhat/13-imt-atomic-swap.spec.ts` — the anvil-interop atomic-swap spec (the atomic
  built-ins are predeployed in the harness chain states, as genesis would).

In production, the IMT proofs are served by the zksync-os-server `zks_getImtInclusionProof` /
`zks_getImtLowNullifierIndex` RPCs (a Rust port of the engine above), paired with the settlement proof
(the chain-batch-root leaf path plus the batch-leaf / chain-tree / shared-tree hops) for the
interop-root half of each proof.
