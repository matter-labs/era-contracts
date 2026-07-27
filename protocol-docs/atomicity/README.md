# Atomic interop without L1 coordination

The `l1-contracts/contracts/atomic-interop/` module makes a multi-leg interop flow **atomic** — no leg's
destination may execute unless _every_ leg was committed in time, and otherwise the committed legs
become refundable — **without a central L1 coordinator**. (Atomicity gates whether execution is
_permitted_, not whether every destination actually runs; see
{protocol-docs/atomicity/security.md#guarantees}.) It rides on the normal interop bundle
path (`InteropCenter.sendBundle` -> `L2AssetRouter` -> `InteropHandler.executeAtomicBundle`) — and is in
fact the _only_ L2->L2 path: the `atomicBundle` attribute is mandatory on every L2->L2 send, since
L1-published (non-atomic) L2->L2 interop was removed; the only non-atomic send left is an L2->L1
withdrawal (see {protocol-docs/interop.md#atomic-bundles}). The only addition to that path is an
**Indexed Merkle Tree (IMT)** per chain that records each leg's commitment, plus per-leg
**IMT proofs** authenticated against the regular **interop-root channel**. There is no extra L1
contract, no global-root registry, and no L2->L1 finality message — finality is proven, not dispatched.
(Each inserted IMT leaf _is_ mirrored into an L2->L1 log, but purely so the tree stays reconstructible
from L1 data; nothing reads it on L1. See {protocol-docs/atomicity/security.md#data-availability}.)

## How to read these docs

This folder is the **canonical home** for the atomic-interop protocol. It is layered: each file opens
with an engineer-facing summary and defers the rigorous arguments to clearly-marked deep-dive sections.

| File                         | Covers                                                                                                   | Audience              |
| ---------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------- |
| this README                  | What atomic interop is, the key values, a lifecycle tour, contracts, genesis, tooling                    | everyone (start here) |
| [imt.md](./imt.md)           | The per-chain commitment tree: how the IMT is used, seeded, and read by the bootloader                   | engineers             |
| [flow.md](./flow.md)         | End-to-end lifecycle, the shared data structures, and the `AtomicFlowManager` state machine              | engineers             |
| [proofs.md](./proofs.md)     | The proof system: the two authenticated clocks, finality, the timeout branches, soundness & completeness | auditors              |
| [recovery.md](./recovery.md) | The timeout/refund path and its best-effort recovery semantics                                           | engineers + auditors  |
| [security.md](./security.md) | Guarantees, non-guarantees, on-chain preconditions, trust assumptions, edge cases                        | auditors              |

The atomic protocol's **integration** with the surrounding stack is documented where that stack lives,
and referenced from here rather than restated: the interop send/execute wiring in
{protocol-docs/interop.md#atomic-bundles}, the asset-router recovery hook in
{protocol-docs/bridging.md#atomic-recovery-hook}, and the generic IMT / chain-batch-root / interop-root
machinery in {protocol-docs/message-root.md}.

## Key values

- `bundleHash = keccak256(abi.encode(bundle))` (`InteropDataEncoding.encodeInteropBundleHash`) — a leg's
  bundle. Chain-specific, because `sourceChainId` is one of the bundle's own fields.
- `flowId = keccak256(abi.encode(preimage))` — binds the preimage `version`, all legs, each leg's source
  chain, the deadline, and the settlement layer. `legBundleHashes` is strictly ascending (a canonical,
  deduplicated order); `legSourceChainIds` is positional (aligned 1:1, may repeat); `deadline` is a
  settlement-layer timestamp. See {protocol-docs/atomicity/flow.md#data-structures}.
- `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, bundleHash)))` — the IMT
  leaf value for a leg. It bakes in `flowId` (hence all legs) and the chain-specific `bundleHash`, so a
  leg's commit value can only ever be inserted into its own source chain's IMT. This self-binding is
  what lets an **inclusion** proof stand on its own while a **non-inclusion** proof must additionally be
  bound to the source chain (see {protocol-docs/atomicity/proofs.md}).

The atomic-send parameters (the full `flowId` **preimage** — `version`, `deadline`,
`settlementLayerChainId`, `legBundleHashes`, `legSourceChainIds` — plus `lowNullifierIndex`) travel
out-of-band as the ERC-7786
`atomicBundle((bytes1,uint64,uint256,bytes32[],uint256[]),uint256)` bundle attribute — deliberately **not**
part of the bundle, so `bundleHash` does not depend on the preimage (which would be circular: the
preimage's leg hashes include the bundle's own hash). The attribute carries the preimage rather than an
opaque `flowId` so that `AtomicFlowManager.append` can recompute the id on-chain and verify the sent
bundle is actually one of the flow's legs. See {protocol-docs/interop.md#atomic-bundles} for the
interop-side send wiring.

## Lifecycle at a glance

1. **Atomic send** (each leg, on its source chain). The user sends the leg's bundle with the
   `atomicBundle` attribute; `AtomicFlowManager.append` validates the preimage and inserts the leg's
   `commitValue` into this chain's IMT. The leg's local state becomes `Committed`.
2. **Root settlement + import.** The bootloader snapshots the IMT root at every batch boundary; the
   snapshot settles into the settlement layer's `MessageRoot` and is re-imported into every chain
   through the standard interop-root channel.
3. **Finalize** (destination). `InteropHandler.executeAtomicBundle(bundle, finalityProof)` proves, via
   the manager, that **every** leg was committed in its source chain's IMT before the deadline; only
   then do the bundle's calls execute.
4. **Timeout / refund.** If a leg never commits in time, a single absence proof authorizes refunds; each
   committed leg reverses its own burn best-effort.

Steps 1 and 3–4 are detailed in [flow.md](./flow.md); the proof mechanics of steps 3–4 in
[proofs.md](./proofs.md); the refund in [recovery.md](./recovery.md); step 2's channel in
{protocol-docs/message-root.md}.

Leg state machine (`LegState`): `Unset -> Committed` (send) `-> Revertable -> Reverted` (timeout path).

## Contracts

| Contract                                                                                                        | Layer | Role                                                                                                                                                                                                                                                                                                                                                                                           |
| --------------------------------------------------------------------------------------------------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `L2InteropCommitmentTree`                                                                                       | L2    | Per-chain append-only **Indexed** Merkle Tree. `insert` is appender-gated (the flow manager). The root is never published — the bootloader reads it straight from the tree's (consensus-critical) storage at batch boundaries; each inserted leaf is separately recorded as an L2->L1 log via `INTEROP_COMMITMENT_LEAF_HOOK` (`0x7004`) for DA. Built-in at `0x10012`. See [imt.md](./imt.md). |
| `AtomicFlowManager`                                                                                             | L2    | `append` (from `InteropCenter`), `requireFlowFinalized` (from `InteropHandler`), `authorizeRefund` / `claimRefund` (timeout). Holds per-leg `LegState`. Built-in at `0x10014`. See [flow.md](./flow.md).                                                                                                                                                                                       |
| `libraries/AtomicInteropProof`                                                                                  | L2    | `verifyInclusion` and `verifyTimeoutAbsence`, `commitValue`, and root authentication against the imported interop root. See [proofs.md](./proofs.md).                                                                                                                                                                                                                                          |
| `IL2InteropCommitmentTree`, `IAtomicFlowManager`, `IAtomicInterop`, `IAtomicRecoverable`, `AtomicInteropErrors` | L2    | Interfaces, shared structs (`ImtProof`, `AtomicFlow`, `AtomicFlowPreimage`, `AtomicFinalityProof`, `LegState`), and errors.                                                                                                                                                                                                                                                                    |

The flow's entry points live outside this directory: `InteropCenter`
(`l1-contracts/contracts/interop/`, `0x1000d`) drives the send + `append`; `InteropHandler`
(`l1-contracts/contracts/interop/`, `0x1000e`) drives `executeAtomicBundle`; `L2AssetRouter`
(`l1-contracts/contracts/bridge/asset-router/`, `0x10003`) does the burn / mint and implements
`IAtomicRecoverable.recoverAtomicCall` for the timeout recovery. The underlying IMT data structure is
`l1-contracts/contracts/common/libraries/IndexedMerkleTree.sol`, documented generically in
{protocol-docs/message-root.md#indexed-merkle-tree-indexedmerkletree}.

> Address `0x10013` is intentionally reserved/empty — it formerly held a global-root importer that was
> removed when atomic interop moved to the interop-root channel.

## ZKsync OS genesis

The two L2 contracts are predeployed in the ZKsync OS genesis (settlement-layer support lives in the
core protocol: the `Executor` pushes batch roots via `addChainBatchRootV32` and verifies imported
dependency roots; the genesis batch leaf is seeded by `MessageRootBase.seedGenesisRoot`):

- registered in the genesis-gen tool (`tools/zksync-os-genesis-gen`) at `0x10012`
  (`L2InteropCommitmentTree`) and `0x10014` (`AtomicFlowManager`) — constants in
  `l1-contracts/contracts/common/l2-helpers/L2ContractAddresses.sol`;
- seeded in `l2-upgrades/L2GenesisForceDeploymentsHelper._initializeV31Contracts`, guarded on
  `_isZKsyncOS && _isGenesisUpgrade` — a pre-existing chain upgrading to v31 has no code at these
  addresses, so calling `initL2` there would revert the whole upgrade. The commitment tree's `initL2`
  seeds the IMT; the manager's `initL2(l1ChainId)` records the L1 chain id every flow's settlement layer
  is checked against.

No further wiring is needed — every collaborator is referenced by its canonical fixed address: the
tree's appender and the manager's tree / interop center / interop handler are constant getters, and the
asset router recognises the manager via `_atomicFlowManagerAddr()`. The manager holds no asset-router
reference at all — it drives recovery generically through `IAtomicRecoverable` on each bundle call's
target (see [recovery.md](./recovery.md)).

## Off-chain tooling

- `l1-contracts/test/anvil-interop/src/helpers/imt-engine-lib.ts` — the off-chain IMT engine: commit
  values, the low-nullifier index for an insert, and the O(log n) inclusion / non-inclusion proofs (must
  match `IndexedMerkleTree` bit-for-bit), plus the settlement-proof byte builder (metadata header, the
  3-hop chain-batch-root leaf path, `l1Timestamp`).
- `l1-contracts/test/anvil-interop/test/hardhat/13-imt-atomic-swap.spec.ts` — the anvil-interop
  atomic-swap spec (the atomic built-ins are predeployed in the harness chain states, as genesis would).

In production, the IMT proofs are served by the zksync-os-server `zks_getImtInclusionProof` /
`zks_getImtLowNullifierIndex` RPCs (a Rust port of the engine above), paired with the settlement proof
(the chain-batch-root leaf path plus the batch-leaf / chain-tree / shared-tree hops) for the
interop-root half of each proof.
