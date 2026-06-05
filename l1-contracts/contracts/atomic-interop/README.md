# Atomic interop without L1 coordination

This module implements atomic cross-chain flows that finalize **without a central L1 coordinator**
(contrast with `../dummy-interop`, where `L1FlowLinker` verifies every commit and dispatches
settlement). Coordination instead happens through an **Indexed Merkle Tree (IMT)** of "parts done",
exposed on L1 and re-imported on L2.

## Flow

1. A user creates a `flowId` binding all legs:
   `flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))`,
   `specHash = keccak256(abi.encode(leg))`.
2. When a participant does their part, the leg's commit value
   `uint256(keccak256(abi.encode(TAG, flowId, specHash)))` is inserted into that chain's
   **indexed** interop IMT (`L2InteropCommitmentTree`). Each leaf carries `{value, nextValue,
nextIndex}` pointers forming a sorted linked list, so both membership and non-membership are
   provable in O(log n).
3. When the chain settles a batch, the operator exposes the chain's IMT root (and a DA commitment to
   its preimage) in the execute batch data; the `Executor` calls `GlobalInteropIMT.submitChainRoot`
   on L1. The registry maintains **two** trees:
   - the **in-place global tree** (`FullMerkle`): `global_imt_root -> chain -> imt`, each chain's
     leaf updated in place;
   - the **append-only history tree** (`DynamicIncrementalMerkle`): a leaf
     `keccak256(block, timestamp, globalRoot)` appended on every advance — `historyRoot` is an
     accumulating commitment to the full sequence of global roots;
     plus a `mapping(globalRoot => blockNumber)` recording where each global root was appended.
4. L2s import the historical global root (`L2GlobalInteropRootImporter`), exactly like an interop
   dependency root.
5. **Finalize (happy path):** anyone proves, against an imported global root whose L1 timestamp is
   `<= deadline`, that _every_ leg's commit value is included (chain IMT path → global tree path).
   Each chain then settles its own leg(s).
6. **Refund (timeout path):** anyone gives an O(log n) non-inclusion proof — a single "low nullifier"
   leaf `L` with `L.value < v < L.nextValue` (or `L.nextValue == 0`) certifies `v` is absent — for a
   chain IMT root that is identical in a global root with timestamp `<= deadline` and in one with
   timestamp `> deadline` (so nothing was inserted in time). The "two roots across the boundary"
   closes the L1-reorg window the design calls out.

## Contracts

| Contract                       | Layer | Role                                                                                                                                                   |
| ------------------------------ | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GlobalInteropIMT`             | L1    | In-place global tree (chain→root) **and** append-only history tree of `(block, timestamp, globalRoot)` snapshots, plus `mapping(globalRoot => block)`. |
| `L2InteropCommitmentTree`      | L2    | Per-chain **Indexed** Merkle Tree (`FullMerkle`-backed); leaves `{value, nextValue, nextIndex}`.                                                       |
| `L2GlobalInteropRootImporter`  | L2    | Stores global roots imported from L1 (trusted supplier / bootloader).                                                                                  |
| `AtomicFlowEscrow`             | L2    | `commitPart` (insert with low-nullifier) / `finalize` / `refund`, gated purely by IMT proofs.                                                          |
| `libraries/AtomicInteropProof` | both  | O(log n) inclusion + low-nullifier non-inclusion verification.                                                                                         |

The `Executor` integration is opt-in per chain (`Admin.setGlobalInteropImt`) and supplied via a new,
backward-compatible execute-data encoding version (`InteropImtExport`); chains that do not opt in are
byte-for-byte unaffected.

## Off-chain tooling

- `test/anvil-interop/imt-engine.ts` — computes commit values, the low-nullifier index for
  `commitPart`, and the O(log n) inclusion / non-inclusion proofs up to the L1 historical global IMT.
- `test/anvil-interop/imt-supplier.ts` — trusted component that reads L1 historical global roots and
  imports them into the L2 importer.

> **Demo scope.** The asset mechanics in `AtomicFlowEscrow` are a self-custodial lock/release
> stand-in for bridge/NTV routing — the focus of this module is the L1-free, IMT-based coordination.
> Exposing the IMT root on L1 is trusted to the operator in the demo; in production the root is part
> of the block commitment and the DA commitment covers the IMT preimage.
