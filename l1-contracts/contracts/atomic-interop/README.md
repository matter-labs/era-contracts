# Atomic interop without L1 coordination

This module makes a multi-leg interop flow **atomic** — every leg executes or none does — **without a
central L1 coordinator**. It rides on the normal interop bundle path (`InteropCenter.sendBundle` ->
`L2AssetRouter` -> `InteropHandler.executeAtomicBundle`); the only addition is an **Indexed Merkle
Tree (IMT)** per chain that records each leg's commitment, plus per-leg **IMT proofs** authenticated
against the regular **interop-root channel** (each chain's IMT root is published to L1 and re-imported
on every chain). There is no extra L1 contract and no global-root registry — finality is proven, not
dispatched.

## Key values

- `bundleHash = keccak256(abi.encode(sourceChainId, bundleBytes))` — a leg's bundle, chain-specific.
- `flowId = keccak256(abi.encode(legBundleHashes, chainIds, deadline))` — binds all legs; both arrays
  strictly ascending, `deadline` is a settlement-layer block number.
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
2. **Root settlement + import.** On every insert the commitment tree publishes `abi.encode(root)` to L1
   via the L2->L1 messenger. That root settles into L1's `MessageRoot` and is re-imported into every
   chain's `L2InteropRootStorage` through the standard interop-root channel — the same channel used for
   all interop, built on both L1 and the gateway, so it works for L1-settling chains too.
3. **Finalize** (destination). `InteropHandler.executeAtomicBundle(bundle, finalityProof)` calls
   `AtomicFlowManager.requireFlowFinalized`, which for **every** leg verifies an IMT **inclusion** proof
   (`AtomicInteropProof.verifyInclusion`): the leg's `commitValue` is present in its source chain's IMT
   as of an authenticated interop root whose settlement-layer block is `<= deadline`. If all legs are
   proven committed in time, the bundle's calls execute (the destination mint). Inclusion is
   self-binding: a `commitValue` only exists in its true source chain's tree, so a proof can only
   succeed against the right chain.
4. **Timeout / refund.** If a leg never commits in time, `AtomicFlowManager.authorizeRefund` takes an
   O(log n) **non-inclusion** proof (`AtomicInteropProof.verifyNonInclusion`): the missing leg's
   `commitValue` is absent from an authenticated root whose settlement-layer block is `> deadline`.
   Since the IMT is append-only, absence after the deadline implies absence at the deadline, so the flow
   can no longer finalize. It marks this chain's `Committed` legs `Revertable`; `claimRefund` then
   reverses each burn via `L2AssetRouter.recoverAtomicBurn`, re-minting to the original depositor.

Leg state machine (`LegState`): `Unset -> Committed` (send) `-> Revertable -> Reverted` (timeout path).

## Contracts

| Contract                                                                                  | Layer | Role                                                                                                                                                                                                               |
| ----------------------------------------------------------------------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `L2InteropCommitmentTree`                                                                 | L2    | Per-chain append-only **Indexed** Merkle Tree (`{value, nextIndex, nextValue}` leaves). `append` is appender-gated (the flow manager); publishes `abi.encode(root)` to L1 on every insert. Built-in at `0x10012`.  |
| `AtomicFlowManager`                                                                       | L2    | `append` (from `InteropCenter`), `requireFlowFinalized` (from `InteropHandler`), `authorizeRefund` / `claimRefund` (timeout). Holds per-leg `LegState`. Built-in at `0x10014`.                                     |
| `libraries/AtomicInteropProof`                                                            | L2    | `verifyInclusion` / `verifyNonInclusion`, `commitValue`, and `_authenticateRoot` — authenticates a `chainImtRoot` against the imported interop root and derives the settlement-layer block for the deadline check. |
| `IL2InteropCommitmentTree`, `IAtomicFlowManager`, `IAtomicInterop`, `AtomicInteropErrors` | L2    | Interfaces, shared structs (`ImtInclusionProof`, `ImtNonInclusionProof`, `AtomicFinalityProof`, `LegState`), and errors.                                                                                           |

The flow's entry points live outside this directory: `InteropCenter` (`interop/`, `0x1000d`) drives the
send + `append`; `InteropHandler` (`interop/`, `0x1000e`) drives `executeAtomicBundle`; `L2AssetRouter`
(`bridge/asset-router/`, `0x10003`) does the burn / mint / `recoverAtomicBurn`, recognising the flow
manager by its canonical address. The underlying IMT data structure is `common/libraries/IndexedMerkleTree.sol`.

> Address `0x10013` is intentionally reserved/empty — it formerly held a global-root importer that was
> removed when atomic interop moved to the interop-root channel.

## ZKsync OS genesis

The two L2 contracts are predeployed in the ZKsync OS genesis (no `Executor` / core-protocol changes):

- registered in the genesis gen tool (`tools/zksync-os-genesis-gen`) at `0x10012`
  (`L2InteropCommitmentTree`) and `0x10014` (`AtomicFlowManager`) — constants in
  `common/l2-helpers/L2ContractAddresses.sol`;
- wired during genesis in `L2GenesisForceDeploymentsHelper._initializeV31Contracts` (ZKsync OS only):
  the commitment tree's appender is set to the flow manager, and the manager is initialized with the
  tree, asset router, interop center, and interop handler. No asset-router registration step is needed —
  the AR recognises the manager via its canonical address (`_atomicFlowManagerAddr()`).

## Off-chain tooling (`test/anvil-interop/`)

- `src/helpers/imt-engine-lib.ts` — the off-chain IMT engine: commit values, the
  low-nullifier index for an insert, and the O(log n) inclusion / non-inclusion proofs (must match
  `IndexedMerkleTreeLib` bit-for-bit).
- `src/helpers/imt-atomic-deployer.ts` — installs the atomic built-ins (`anvil_setCode`) on the anvil
  harness chains and wires them as genesis would, for the hardhat spec.
- `test/hardhat/13-imt-atomic-swap.spec.ts` — the anvil-interop atomic-swap spec.

In production, the IMT proofs are served by the zksync-os-server `zks_getImtInclusionProof` /
`zks_getImtLowNullifierIndex` RPCs (a Rust port of the engine above), paired with `zks_getL2ToL1LogProof`
for the message/interop-root half of each proof.
