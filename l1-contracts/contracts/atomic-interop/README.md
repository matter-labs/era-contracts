# Atomic interop without L1 coordination

This module makes a multi-leg interop flow **atomic** — every leg executes or none does — **without a
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
- `flowId = keccak256(abi.encode(legBundleHashes, legSourceChainIds, deadline, settlementLayerChainId))` —
  binds all legs, each leg's source chain, the deadline, and the settlement layer. `legBundleHashes` is
  strictly ascending (canonical order + dedup); `legSourceChainIds` is positional (aligned 1:1, may
  repeat); `deadline` is a settlement-layer timestamp.
- `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))` — the IMT
  leaf value for a leg. It bakes in `flowId` (hence all legs) and the chain-specific `bundleHash`, so a
  leg's commit value can only ever be inserted into its own source chain's IMT.

The atomic-send parameters (`flowId`, `deadline`, `lowNullifierIndex`) travel out-of-band as the
ERC-7786 `atomicBundle(bytes32,uint64,uint256)` bundle attribute — deliberately **not** part of the
bundle, so `bundleHash` does not depend on `flowId` (which would be circular).

## Flow

1. **Atomic send** (each leg, on its source chain). The user calls `InteropCenter.sendBundle` with the
   `atomicBundle` attribute. The source burn flows through the normal `initiateIndirectCall` /
   `L2AssetRouter` path; instead of publishing the bundle to L1, the InteropCenter calls
   `AtomicFlowManager.append`, which inserts `commitValue` into this chain's `L2InteropCommitmentTree`
   (an append-only **indexed** Merkle tree; leaves carry `{value, nextIndex, nextValue}` so both
   membership and non-membership are provable in O(log n)). The leg's local state becomes `Committed`.
2. **Root settlement + import.** The bootloader reads the tree's root directly from storage at every
   batch boundary and commits both snapshots into the batch's chain batch root (leaf 2 = begin, leaf 3
   = end; see `common/libraries/ChainBatchRootTree.sol`). The chain batch root settles into the
   settlement layer's `MessageRoot` and is re-imported into every chain's `L2InteropRootStorage`
   through the standard interop-root channel — the same channel used for all interop, built on both L1
   and the gateway, so it works for L1-settling chains too.
3. **Finalize** (destination). `InteropHandler.executeAtomicBundle(bundle, finalityProof)` calls
   `AtomicFlowManager.requireFlowFinalized`, which for **every** leg verifies an IMT **inclusion** proof
   (`AtomicInteropProof.verifyInclusion`): the leg's `commitValue` is present in its source chain's
   **batch-end** IMT root (chain-batch-root leaf 3, authenticated with an exact-depth 3-sibling path)
   of a batch that settled strictly before the deadline (`l1Timestamp < deadline`) on the flow's
   `settlementLayerChainId`, and the proof's `sourceChainId` matches the
   leg's declared `legSourceChainIds[i]`. If all legs are proven committed in time, the bundle's calls
   execute (the destination mint). A `commitValue` can only exist in its true source chain's tree, so
   inclusion is self-binding; non-inclusion is not, which is why the source chain is checked explicitly.
4. **Timeout / refund.** If a leg never commits in time, `AtomicFlowManager.authorizeRefund` takes a
   single absence proof (`AtomicInteropProof.verifyTimeoutAbsence`). The proof anchors on an
   **aggregated root created after the deadline** — the imported interop root's creation timestamp
   `T` (stored as `interopRootTimestamps` next to the root and double checked on the settlement layer
   during batch execution) must satisfy `T >= deadline` — plus one batch of the source chain inside
   that root, with two branches on the batch's inclusion time `t` (the `l1Timestamp` bound into the
   batch leaf when the batch root was aggregated):
   - `t >= deadline` (late batch): the missing leg's `commitValue` is absent from the **batch-begin**
     IMT root (leaf 2). Since the IMT is append-only, `begin(N) == end(N-1)`, and `t` is monotone,
     absence at the begin of a late batch means the value was not committed in any in-time batch.
   - `t < deadline` (in-time batch): the batch is additionally proven to be the chain's **last batch
     inside the aggregated root** (every left-child hop of the batch-leaf path carries the
     empty-subtree hash), and the `commitValue` is absent from the **batch-end** IMT root (leaf 3).
     Any batch aggregated after the anchor root has `t' >= T >= deadline`, so that end root is the
     final IMT state reachable in time. This branch keeps a source chain that **halts** (never
     settles a post-deadline batch) refundable — closing the previous liveness gap.
     Neither branch can succeed for an on-time or already-finalized leg, while a genuinely missing (or
     late-committed) leg is always refundable. Every registered chain has at least one batch inside the
     shared root — `MessageRoot` seeds a genesis batch leaf (empty-IMT chain batch root) at chain
     registration — so the "last batch" required by the second branch always exists.
     The proof is bound to the missing leg's source chain and settlement layer. It
     marks this chain's `Committed` legs `Revertable`; `claimRefund` then reverses each burn by asking the
     call's target to recover itself via `IAtomicRecoverable.recoverAtomicCall` (implemented by
     `L2AssetRouter`), re-minting to the original depositor. Recovery is **best-effort**: each target
     reverses the calls it recognises (an asset-router deposit re-mints the burned funds) and returns
     `false` for calls that move no funds and have nothing to reverse (e.g. flipping a flag); the refund
     succeeds as long as at least one call recovered. Consequently the protocol does not guarantee full
     refundability of an arbitrary bundle — making a fund-moving leg recoverable (an asset-router deposit)
     is the flow author's responsibility. Atomic sends reject only native-`value` legs (`InteropCenter`),
     since those can never be reversed.

Leg state machine (`LegState`): `Unset -> Committed` (send) `-> Revertable -> Reverted` (timeout path).

## Timeout-protocol preconditions

The timeout proof relies on three preconditions, each enforced on chain:

1. **Every chain has at least one batch inside the settlement layer's message root.** Enforced by
   `MessageRootBase._addNewChain`, which seeds a genesis batch leaf (the empty-IMT chain batch root,
   `ChainBatchRootTree.genesisChainBatchRoot()`) into the chain's tree at registration. This
   guarantees the "last batch inside the aggregated root" required by the in-time timeout branch
   always exists, even for a chain that halts before settling anything.
2. **Interop only involves registered chains.** A leg's commit value only "counts" once it settles:
   both finality and timeout proofs resolve against the source chain's batches inside the settlement
   layer's message root, and `MessageRoot.addChainBatchRoot` only accepts batches from registered
   chains (which, per precondition 1, already have their genesis leaf). A flow declaring an
   unregistered source chain simply can never finalize, and stays refundable against that chain's
   (genesis-only) tree once the chain registers — so destinations should only accept flows whose
   source chains are registered.
3. **Every batch leaf carries the timestamp at which it entered the shared root.** Enforced by
   `MessageRoot.addChainBatchRoot`, which folds the settlement-layer `block.timestamp` into the batch
   leaf (`MessageHashing.batchLeafHash`); the timestamp is therefore proven by the same inclusion
   proof that authenticates the IMT root. Aggregated roots additionally carry their own creation
   timestamp (`historicalRootTimestamp` on the settlement layer, imported as
   `interopRootTimestamps` and double checked at batch execution), which anchors the "root from
   after the deadline" requirement.

## Contracts

| Contract                                                                                  | Layer | Role                                                                                                                                                                                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `L2InteropCommitmentTree`                                                                 | L2    | Per-chain append-only **Indexed** Merkle Tree (`{value, nextIndex, nextValue}` leaves). `insert` is appender-gated (the flow manager). Publishes nothing: the bootloader reads the root straight from its (consensus-critical) storage at batch boundaries. Built-in at `0x10012`.                                                              |
| `AtomicFlowManager`                                                                       | L2    | `append` (from `InteropCenter`), `requireFlowFinalized` (from `InteropHandler`), `authorizeRefund` / `claimRefund` (timeout). Holds per-leg `LegState`. Built-in at `0x10014`.                                                                                                                                                                  |
| `libraries/AtomicInteropProof`                                                            | L2    | `verifyInclusion` and `verifyTimeoutAbsence` (for inclusion and timeout proofs respectively), `commitValue`, and the private `_authenticateRoot` — authenticates a `chainImtRoot` as a chain-batch-root leaf (2 = begin / 3 = end, exact depth) against the imported interop root and derives the batch's `l1Timestamp` for the deadline check. |
| `IL2InteropCommitmentTree`, `IAtomicFlowManager`, `IAtomicInterop`, `AtomicInteropErrors` | L2    | Interfaces, shared structs (`ImtProof`, `AtomicFlow`, `AtomicFinalityProof`, `LegState`), and errors.                                                                                                                                                                                                                                           |

The flow's entry points live outside this directory: `InteropCenter` (`interop/`, `0x1000d`) drives the
send + `append`; `InteropHandler` (`interop/`, `0x1000e`) drives `executeAtomicBundle`; `L2AssetRouter`
(`bridge/asset-router/`, `0x10003`) does the burn / mint and implements `IAtomicRecoverable.recoverAtomicCall`
for the timeout recovery, recognising the flow manager by its canonical address. The underlying IMT data structure is `common/libraries/IndexedMerkleTree.sol`.

> Address `0x10013` is intentionally reserved/empty — it formerly held a global-root importer that was
> removed when atomic interop moved to the interop-root channel.

## ZKsync OS genesis

The two L2 contracts are predeployed in the ZKsync OS genesis (no `Executor` / core-protocol changes):

- registered in the genesis gen tool (`tools/zksync-os-genesis-gen`) at `0x10012`
  (`L2InteropCommitmentTree`) and `0x10014` (`AtomicFlowManager`) — constants in
  `common/l2-helpers/L2ContractAddresses.sol`;
- seeded during genesis in `L2GenesisForceDeploymentsHelper._initializeV31Contracts` (ZKsync OS only):
  the commitment tree's one-time `initialize()` seeds the IMT. No wiring or registration step is needed —
  every collaborator is referenced by its canonical fixed address: the tree's appender and the manager's
  tree / interop center / interop handler are constant getters, and the AR recognises the manager via
  `_atomicFlowManagerAddr()`. The manager no longer holds an asset-router reference at all — it drives
  recovery generically through `IAtomicRecoverable` on each bundle call's target.

## Off-chain tooling (`test/anvil-interop/`)

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
