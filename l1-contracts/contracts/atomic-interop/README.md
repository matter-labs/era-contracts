# Atomic interop without L1 coordination

This module implements atomic cross-chain flows that finalize **without a central L1 coordinator**
(contrast with `../dummy-interop`, where `L1FlowLinker` verifies every commit and dispatches
settlement). It keeps `dummy-interop`'s `SendSpec` / `SpecState` model and the same asset routing
through the asset router + native token vault, but replaces the L1-linker authorization with
**Indexed Merkle Tree (IMT) proofs** against a global interop-IMT exposed on L1 and re-imported on L2.

## Flow

1. A user creates a `flowId` binding all legs:
   `flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))`,
   `specHash = keccak256(abi.encode(spec))`, where each leg is a `SendSpec`
   `{destChainId, recipient, originChainId, originToken, amount, erc20Data, depositor}`.
2. `commitSend` — the source depositor locks `amount` of `originToken` and the spec's commit value
   `uint256(keccak256(abi.encode(TAG, flowId, specHash)))` is inserted into the origin chain's
   **indexed** interop IMT (`L2InteropCommitmentTree`). Each leaf carries `{value, nextValue,
nextIndex}` pointers, so both membership and non-membership are provable in O(log n).
3. On batch settlement the operator exposes the chain's IMT root in the execute batch data; the
   chain's `Executor` (its diamond proxy) calls `GlobalInteropIMT.submitChainRoot`. The only
   authorized submitter for a chain is its diamond proxy, **resolved from the Bridgehub** — there
   are no owner-managed submitter roles. The registry maintains:
   - the **in-place global tree** (`FullMerkle`): `global_imt_root -> chain -> imt`;
   - the **append-only history tree** (`DynamicIncrementalMerkle`) of
     `keccak256(block, timestamp, globalRoot)` snapshots (`historyRoot`), plus
     `mapping(globalRoot => blockNumber)`.
     Batch numbers must be strictly consecutive (no gaps).
4. L2s import the historical global root (`L2GlobalInteropRootImporter`).
5. `authorize` — once a caller proves (against an imported global root with timestamp `<= deadline`)
   that _every_ spec was committed in time, the specs relevant to this chain become `Executable`.
6. `execute` — performs the asset op through AR/NTV: burn on the source, mint on the destination
   (identical to `L2FlowEscrow`).
7. `authorizeRefund` / `claimRefund` — the timeout path: an O(log n) low-nullifier non-inclusion
   proof (chain IMT root identical in a global root `<= deadline` and one `> deadline`) marks source
   specs `Revertable`, then the depositor reclaims the lock.

## Contracts

| Contract                       | Layer | Role                                                                                                               |
| ------------------------------ | ----- | ------------------------------------------------------------------------------------------------------------------ |
| `GlobalInteropIMT`             | L1    | In-place global tree + append-only history tree; submitter = the chain's diamond proxy (from the Bridgehub).       |
| `L2InteropCommitmentTree`      | L2    | Per-chain **Indexed** Merkle Tree; leaves `{value, nextValue, nextIndex}`.                                         |
| `L2GlobalInteropRootImporter`  | L2    | Stores global roots imported from L1.                                                                              |
| `AtomicFlowEscrow`             | L2    | `commitSend` / `authorize` / `execute` / `authorizeRefund` / `claimRefund`, AR/NTV asset routing, IMT-proof gated. |
| `libraries/AtomicInteropProof` | both  | O(log n) inclusion + low-nullifier non-inclusion verification.                                                     |

The `Executor` integration is opt-in per chain (`Admin.setGlobalInteropImt`) and supplied via a new,
backward-compatible execute-data encoding version (`InteropImtExport` = `{imtRoot}`); chains that do
not opt in are byte-for-byte unaffected.

## Off-chain tooling (`test/anvil-interop/`)

- `imt-engine.ts` — commit values, the low-nullifier index for `commitSend`, and the O(log n)
  inclusion / non-inclusion proofs up to the L1 historical global IMT.
- `imt-supplier.ts` — trusted component that imports L1 historical global roots into the L2 importer.
- `atomic-flow-cli.ts` — interactive, JSON-backed demo: `register-flow-id`, `list-flows`,
  `flow-info`, `commit-send`, `check-status`, `finalize`.

> **Demo scope.** Exposing the IMT root on L1 is trusted to the operator in the demo (the chain's
> diamond submits it); in production the root is part of the block commitment. The AR/NTV asset
> mechanics match `L2FlowEscrow` and are exercised in the anvil-interop suite; the Foundry unit tests
> mock the asset router to isolate the escrow's proof-gating + state machine.
