# Atomic interop without L1 coordination

This module implements atomic cross-chain flows that finalize **without a central L1 coordinator**
(contrast with `../dummy-interop`, where `L1FlowLinker` verifies every commit and dispatches
settlement). Coordination instead happens through an **incremental Merkle tree (IMT)** of "parts
done", exposed on L1 and re-imported on L2.

## Flow

1. A user creates a `flowId` binding all legs:
   `flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))`,
   `specHash = keccak256(abi.encode(leg))`.
2. When a participant does their part, a leaf
   `keccak256(abi.encode(TAG, flowId, specHash))` is appended to that chain's interop IMT
   (`L2InteropCommitmentTree`).
3. When the chain settles a batch, the operator exposes the chain's IMT root (and a DA commitment to
   its preimage) in the execute batch data; the `Executor` calls `GlobalInteropIMT.submitChainRoot`
   on L1. The registry keeps:
   - `global_imt_root -> chain -> imt` — each chain's leaf is updated **in place** in a `FullMerkle`
     tree;
   - `historical_root -> (block, timestamp)` — **append-only** snapshots of the global root.
4. L2s import the historical global root (`L2GlobalInteropRootImporter`), exactly like an interop
   dependency root.
5. **Finalize (happy path):** anyone proves, against an imported global root whose L1 timestamp is
   `<= deadline`, that _every_ leg's commit leaf is included (chain IMT path → global tree path).
   Each chain then settles its own leg(s).
6. **Refund (timeout path):** anyone proves a leg is absent across the deadline boundary — the
   chain's IMT root is identical in a global root with timestamp `<= deadline` and in one with
   timestamp `> deadline` (so nothing was inserted in time), and the full disclosed leaf set
   recomputes to that root without the target leaf. The "two roots across the boundary" closes the
   L1-reorg window the design calls out.

## Contracts

| Contract                       | Layer | Role                                                                  |
| ------------------------------ | ----- | --------------------------------------------------------------------- |
| `GlobalInteropIMT`             | L1    | Aggregates chain IMT roots into a global tree; append-only history.   |
| `L2InteropCommitmentTree`      | L2    | Per-chain append-only interop IMT (`DynamicIncrementalMerkle`).       |
| `L2GlobalInteropRootImporter`  | L2    | Stores global roots imported from L1 (trusted supplier / bootloader). |
| `AtomicFlowEscrow`             | L2    | `commitPart` / `finalize` / `refund`, gated purely by IMT proofs.     |
| `libraries/AtomicInteropProof` | both  | Layered inclusion + non-inclusion verification.                       |

The `Executor` integration is opt-in per chain (`Admin.setGlobalInteropImt`) and supplied via a new,
backward-compatible execute-data encoding version (`InteropImtExport`); chains that do not opt in are
byte-for-byte unaffected.

## Off-chain tooling

- `test/anvil-interop/imt-engine.ts` — given an RPC + item, builds the chain-IMT inclusion proof and
  the full proof up to the L1 historical global IMT (and non-inclusion proofs for refunds).
- `test/anvil-interop/imt-supplier.ts` — trusted component that reads L1 historical global roots and
  imports them into the L2 importer.

> **Demo scope.** The asset mechanics in `AtomicFlowEscrow` are a self-custodial lock/release
> stand-in for bridge/NTV routing — the focus of this module is the L1-free, IMT-based coordination.
> Exposing the IMT root on L1 is trusted to the operator in the demo; in production the root is part
> of the block commitment and the DA commitment covers the IMT preimage.
