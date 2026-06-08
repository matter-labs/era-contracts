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
3. On batch settlement the chain's IMT root is exposed on L1 via `GlobalInteropIMT.submitChainRoot`.
   This is currently a **permissionless stub** (anyone — e.g. the demo relayer — may submit any
   chain's root); the production check (only the chain's diamond proxy, from the Bridgehub) is
   preserved via `chainDiamond` so it is trivial to re-enable. The registry maintains:
   - the **in-place global tree** (`FullMerkle`): `global_imt_root -> chain -> imt`;
   - the **append-only history tree** (`DynamicIncrementalMerkle`) of
     `keccak256(block, timestamp, globalRoot)` snapshots, plus `mapping(globalRoot => blockNumber)`.
     Batch numbers must be strictly consecutive.
4. L2s import the historical global root (`L2GlobalInteropRootImporter`) — also a permissionless stub.
5. `authorize` — proves the flow was committed in time and marks this chain's specs `Executable`.
   Specs that originate on the verifying chain were committed there, so they need **no** proof (their
   local `Committed` state is checked); only specs from other chains require an inclusion proof
   (against an imported global root with timestamp `<= deadline`).
6. `execute` — performs the asset op through AR/NTV: burn on the source, mint on the destination.
7. `authorizeRefund` / `claimRefund` — the timeout path: an O(log n) low-nullifier non-inclusion
   proof (chain IMT root identical in a global root `<= deadline` and one `> deadline`) marks source
   specs `Revertable`, then the depositor reclaims the lock.

## Contracts

| Contract                       | Layer | Role                                                                                                                                                                                    |
| ------------------------------ | ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GlobalInteropIMT`             | L1    | In-place global tree + append-only history tree. `submitChainRoot` is a permissionless stub; the Bridgehub diamond lookup (`chainDiamond`) is preserved for re-enabling access control. |
| `L2InteropCommitmentTree`      | L2    | Per-chain **Indexed** Merkle Tree; leaves `{value, nextValue, nextIndex}`.                                                                                                              |
| `L2GlobalInteropRootImporter`  | L2    | Stores global roots imported from L1 (permissionless stub).                                                                                                                             |
| `AtomicFlowEscrow`             | L2    | `commitSend` / `authorize` / `execute` / `authorizeRefund` / `claimRefund`, AR/NTV asset routing, IMT-proof gated.                                                                      |
| `libraries/AtomicInteropProof` | both  | O(log n) inclusion + low-nullifier non-inclusion verification.                                                                                                                          |

## ZKsync OS genesis

The three L2 contracts are predeployed in the ZKsync OS genesis (no `Executor`/core protocol changes
are involved):

- registered in the genesis gen tool `tools/zksync-os-genesis-gen/src/consts.rs` (`INITIAL_CONTRACTS`,
  `SystemProxy`) at addresses `0x10012` (`L2InteropCommitmentTree`), `0x10013`
  (`L2GlobalInteropRootImporter`), `0x10014` (`AtomicFlowEscrow`) — constants in
  `common/l2-helpers/L2ContractAddresses.sol`;
- wired during genesis in `L2GenesisForceDeploymentsHelper._initializeV31Contracts` (ZKsync OS only):
  the tree's appender is set to the escrow, and the escrow is pointed at the tree, importer, asset
  router and native token vault. The importer is permissionless and needs no init.

## Off-chain tooling (`test/anvil-interop/`)

- `imt-engine.ts` — commit values, the low-nullifier index for `commitSend`, and the O(log n)
  inclusion / non-inclusion proofs.
- `imt-supplier.ts` — imports L1 historical global roots into the L2 importer.
- `atomic-root-relayer.ts` — demo daemon that, each cycle, submits every L2's IMT root to L1 and
  imports the resulting global roots back into every L2; one private key, takes the L1 RPC + per-chain
  L2 RPCs/addresses.
- `atomic-flow-cli.ts` — interactive, JSON-backed demo: `register-flow-id`, `list-flows`,
  `flow-info`, `commit-send`, `check-status`, `finalize`.

> **Demo scope.** `submitChainRoot` / `importGlobalRoot` are temporary permissionless stubs (the
> production access models — chain-diamond submitter; bootloader-delivered import — are documented in
> the contracts and easy to restore). The AR/NTV asset mechanics match `L2FlowEscrow` and are
> exercised in the anvil-interop suite; the Foundry unit tests mock the asset router to isolate the
> escrow's proof-gating + state machine.
