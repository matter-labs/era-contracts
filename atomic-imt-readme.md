# Atomic interop without L1 coordination (IMT-based)

This document explains the **architecture** of the L1‑free atomic interop feature and gives
**hands‑on instructions** for trying it out.

It is the advanced counterpart of the L1‑coordinated `dummy-interop` stack
(`l1-contracts/contracts/dummy-interop`, `L1FlowLinker` + `L2FlowEscrow`). The difference: there is
**no central L1 coordinator**. Flows finalize purely from Merkle proofs against an incremental
Merkle tree (IMT) of "parts done" that each chain exposes on L1 and that L2s re‑import.

- Contracts: `l1-contracts/contracts/atomic-interop/` (and its `README.md`).
- Tests: `l1-contracts/test/foundry/l1/unit/concrete/AtomicInterop/`.
- Tooling: `l1-contracts/test/anvil-interop/imt-engine.ts`, `imt-supplier.ts`.

---

## 1. Architecture

### 1.1 The idea in one paragraph

Each chain keeps an **append‑only interop IMT**. When a participant "does their part" in a flow, a
leaf is appended. When the chain settles a batch, its current IMT root (plus a DA commitment to the
tree's preimage) is exposed on L1 and folded into a **global IMT** that aggregates every chain's
root. L2s re‑import the historical global root. To **finalize**, anyone proves — against an imported
global root whose L1 timestamp is `≤ deadline` — that *every* leg of the flow was committed in time.
To **refund** after a timeout, anyone proves a leg is provably *absent* across the deadline boundary.
No L1 contract ever "authorizes" settlement; it only stores roots.

### 1.2 Components

```
        L2 chain A                         L1                         L2 chain B
  ┌────────────────────┐         ┌──────────────────────┐      ┌────────────────────┐
  │ AtomicFlowEscrow A  │         │  GlobalInteropIMT     │      │ AtomicFlowEscrow B  │
  │  - commitPart  ─────┼──┐      │  global tree (Full-   │   ┌──┼─ commitPart        │
  │  - finalize         │  │      │   Merkle): chain→root │   │  │  finalize          │
  │  - refund           │  │      │   (updated in place)  │   │  │  refund            │
  └─────────┬──────────┘  │      │  history: (block,ts)→ │   │  └─────────┬──────────┘
            │ append leaf  │      │   globalRoot (append) │   │            │ append leaf
            ▼              │      └───────────▲───────────┘   │            ▼
  ┌────────────────────┐  │ submitChainRoot   │ submitChainRoot           ┌────────────────────┐
  │ L2InteropCommitment │  └──(Executor on────┘──(Executor on─────────────│ L2InteropCommitment │
  │ Tree A (IMT)        │       batch execute)      batch execute)        │ Tree B (IMT)        │
  └────────────────────┘                                                  └────────────────────┘
            ▲                       │ historical global root                        ▲
            │                       ▼  (imt-supplier)                               │
  ┌────────────────────┐   ┌──────────────────────────┐            ┌────────────────────┐
  │ L2GlobalInterop-    │◄──┤  imt-supplier.ts          ├───────────►│ L2GlobalInterop-   │
  │ RootImporter A      │   │  (trusted: reads L1,      │            │ RootImporter B     │
  └────────────────────┘   │   imports to each L2)     │            └────────────────────┘
                           └──────────────────────────┘
   imt-engine.ts builds inclusion / non-inclusion proofs from these trees for finalize / refund.
```

| Contract | Layer | Role |
|---|---|---|
| `GlobalInteropIMT` | L1 | Aggregates per‑chain IMT roots into a `FullMerkle` global tree (leaf updated **in place** per chain) and records **append‑only** `(block, timestamp) → globalRoot` snapshots. |
| `L2InteropCommitmentTree` | L2 | Per‑chain append‑only interop IMT (`DynamicIncrementalMerkle`). One leaf per "part done". |
| `L2GlobalInteropRootImporter` | L2 | Stores global roots imported from L1, keyed by L1 block number + timestamp. |
| `AtomicFlowEscrow` | L2 | `commitPart` / `finalize` / `refund`. State per `(flowId, specHash)`: `Unset → Committed → Finalized` (happy) or `→ Refunded` (timeout). |
| `libraries/AtomicInteropProof` | both | Pure verification: layered inclusion and non‑inclusion. |

### 1.3 Identifiers and leaves

- `specHash = keccak256(abi.encode(leg))` where `FlowLeg = { chainId, token, amount, payer, payee }`.
- `flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))` — both arrays strictly
  ascending (sorted + deduplicated). This is the agreement; the escrow recomputes and checks it.
- Commit leaf appended to a chain's IMT: `keccak256(abi.encode(TAG, flowId, specHash))`,
  `TAG = bytes4(keccak256("AtomicInterop.commit.v1"))`.
- Global‑tree leaf for a chain: `keccak256(abi.encodePacked(chainImtRoot, chainId))`.
- Empty/zero leaf for both trees: `bytes32(0)`.

`DynamicIncrementalMerkle` (chain IMT) and `FullMerkle` (global tree) produce **identical roots and
paths** for the same leaves, so on‑chain checks reuse `Merkle.calculateRoot` and the off‑chain engine
uses one tree builder for both.

### 1.4 Lifecycle

1. **Create flow** (off‑chain): pick legs, compute `specHash`es and `flowId`.
2. **`commitPart(flowId, leg)`** on the leg's chain: the payer locks `amount` of `token`; the escrow
   appends the commit leaf to `L2InteropCommitmentTree`.
3. **Expose on L1**: when the chain settles a batch, the operator includes the chain's IMT root + DA
   commitment in the execute batch data; the `Executor` calls `GlobalInteropIMT.submitChainRoot`,
   which updates the chain's leaf in place and snapshots the new global root for the current L1
   `(block, timestamp)`.
4. **Import on L2**: the `imt-supplier` reads L1 history and calls
   `L2GlobalInteropRootImporter.importGlobalRoot(block, timestamp, globalRoot)` on each L2.
5. **`finalize(flowId, legs, chainIds, deadline, proofs[])`** (permissionless): for every leg, an
   inclusion proof shows the commit leaf is in its chain's IMT and that root is inside an imported
   global root with timestamp `≤ deadline`. The chain then releases its own leg(s) to the payee.
6. **`refund(flowId, legs, chainIds, deadline, missingLegIndex, proof)`** (permissionless, timeout):
   a non‑inclusion proof shows a leg's commit leaf is absent — its chain's IMT root is identical in a
   global root with timestamp `≤ deadline` and in one with timestamp `> deadline` (nothing was added
   across the boundary), and the disclosed full leaf set recomputes to that root without the target
   leaf. The chain returns its locked leg(s) to the payer.

### 1.5 Proof layers

**Inclusion** (`ImtInclusionProof`): `commitLeaf —(imtProof)→ chainImtRoot —(globalProof)→
importedGlobalRoot`, with `importedTimestamp ≤ deadline`.

**Non‑inclusion** (`ImtNonInclusionProof`): two global proofs for the same chain leaf — one against a
root with `timestamp ≤ deadline` (`G1`), one with `timestamp > deadline` (`G2`) — plus the full leaf
set that recomputes to `chainImtRoot` and does **not** contain the target leaf. Requiring the chain's
IMT root to be the same across the boundary closes the "inserted just past the deadline / L1 reorg"
window from the design.

### 1.6 Executor integration (opt‑in, backward compatible)

The chain's IMT root reaches L1 the same way interop dependency roots do today: the operator supplies
it in the execute batch data and the `Executor` forwards it.

- New execute‑data encoding version `SUPPORTED_ENCODING_VERSION_EXECUTE_WITH_IMT = 2` carrying a
  per‑batch `InteropImtExport { imtRoot, daCommitment }` (decoded by
  `BatchDecoder.decodeExecuteImtExports`).
- `ExecutorFacet._exportInteropImtRoots` calls `GlobalInteropIMT.submitChainRoot` on L1.
- Gated by a new `ZKChainStorage.globalInteropImt` slot, set via `Admin.setGlobalInteropImt`. If a
  chain does not opt in (slot is zero) or sends legacy v1 execute data, behavior is **byte‑for‑byte
  unchanged**.

### 1.7 Trust assumptions / demo simplifications

- **Exposing the IMT root on L1** is trusted to the operator in the demo. In production the IMT root
  is part of the block commitment and the DA commitment covers the IMT preimage.
- **The `imt-supplier`** is a trusted EOA, mirroring how `L2InteropRootStorage`'s bootloader path is
  mocked. In production the bootloader delivers the global root as an interop dependency.
- **Asset mechanics** in `AtomicFlowEscrow` are a self‑custodial lock/release stand‑in for bridge/NTV
  routing; swapping in AR/NTV settlement does not change the proof logic.

---

## 2. Trying it out

### 2.1 Prerequisites

A standard Foundry `forge` is enough for the contracts and the test demo (the AtomicInterop tests are
plain Foundry unit/integration tests — no zkSync VM needed). The version used here:

```bash
forge --version   # forge 1.5.x
```

For the off‑chain CLIs you need Node + the repo's dependencies installed (`yarn install` at the repo
root). Note: `yarn` enforces Node ≥ 20; if you are on Node 18 run the TypeScript tools via
`npx ts-node ...` directly (as shown below) instead of through `yarn`.

### 2.2 Fastest path — run the demo as a test

The end‑to‑end lifecycle (commit → expose on L1 → import on L2 → finalize, and the timeout → refund
path) is exercised as a two‑chain scenario (using `vm.chainId` to simulate two L2s in one EVM):

```bash
cd l1-contracts
forge build
forge test --match-path "test/foundry/l1/unit/concrete/AtomicInterop/*" -vv
```

What the suites demonstrate:

| Test | Shows |
|---|---|
| `AtomicFlowEscrow.t.sol::test_finalize_happyPath_bothLegsSettle` | Full happy path: both legs commit on their chains, roots are exposed to `GlobalInteropIMT`, the global root is imported on both L2s, and both escrows finalize to the payees from inclusion proofs. |
| `…::test_refund_whenLegMissingAcrossDeadline` | Timeout path: one leg never commits; a non‑inclusion proof across the deadline boundary lets the other chain refund its payer. |
| `…::test_finalize_revertsWhenImportedAfterDeadline` | Finalize is rejected if the imported global root's timestamp is past the deadline. |
| `…::test_refund_revertsIfLegActuallyPresent` | Refund is rejected if the "missing" leg is in fact present. |
| `…::test_commitPart_reverts*` | Commit validation: wrong chain, payer mismatch, zero amount, double commit. |
| `ExecutorImtExport.t.sol::test_execute_exportsImtRootToRegistry` | A chain that opted in exports its IMT root to `GlobalInteropIMT` on batch execute (via the new encoding version). |
| `ExecutorImtExport.t.sol::test_execute_legacyPath_doesNotTouchRegistry` | Legacy (v1) execute data leaves the registry untouched. |
| `GlobalInteropIMT.t.sol`, `L2InteropCommitmentTree.t.sol`, `L2GlobalInteropRootImporter.t.sol` | Unit behavior of each building block, including that on‑chain Merkle paths verify against an independently rebuilt tree. |

Run a single scenario with traces:

```bash
forge test --match-test test_finalize_happyPath_bothLegsSettle -vvvv
```

### 2.3 Using the off‑chain tooling against a live deployment

The two CLIs operate on **deployed** contracts and live RPCs. Build artifacts first so the ABIs are
available (`cd l1-contracts && forge build`), then run from `l1-contracts/test/anvil-interop/`.

#### IMT engine — build proofs

```bash
cd l1-contracts/test/anvil-interop

# Compute the commit leaf for a (flowId, specHash):
npx ts-node imt-engine.ts leaf --flow-id 0x<flowId> --spec-hash 0x<specHash>

# Inclusion path of a leaf within one chain's IMT (chain layer only):
npx ts-node imt-engine.ts chain-proof \
  --l2-rpc http://localhost:9545 --tree 0x<L2InteropCommitmentTree> --leaf 0x<leaf>

# Full inclusion proof up to the L1 historical global root — this is exactly the JSON shape of the
# ImtInclusionProof struct AtomicFlowEscrow.finalize expects:
npx ts-node imt-engine.ts full-proof \
  --l1-rpc http://localhost:8545 --l2-rpc http://localhost:9545 \
  --tree 0x<L2InteropCommitmentTree> --registry 0x<GlobalInteropIMT> \
  --chain-id 271 --leaf 0x<leaf> --l1-block <l1BlockWithRoot>

# Non-inclusion proof for the refund path (ImtNonInclusionProof JSON):
npx ts-node imt-engine.ts non-inclusion \
  --l1-rpc http://localhost:8545 --l2-rpc http://localhost:9545 \
  --tree 0x<L2InteropCommitmentTree> --registry 0x<GlobalInteropIMT> \
  --chain-id 272 --leaf 0x<missingLeaf> \
  --l1-block-before <blockBeforeDeadline> --l1-block-after <blockAfterDeadline>
```

#### IMT supplier — import L1 global roots to L2

```bash
# One-shot: import every recorded L1 global root not yet on this L2.
npx ts-node imt-supplier.ts \
  --l1-rpc http://localhost:8545 --l2-rpc http://localhost:9545 \
  --registry 0x<GlobalInteropIMT> --importer 0x<L2GlobalInteropRootImporter> \
  --pk 0x<supplierPrivateKey>

# Continuous: keep polling L1 every 5s and import new roots as they appear.
npx ts-node imt-supplier.ts ... --poll 5
```

### 2.4 Sketch of a manual end‑to‑end run

If you want to drive it by hand against (for example) two `anvil` instances, the moving parts are:

1. **Deploy** on L1: `GlobalInteropIMT(owner)`. On each L2: `L2InteropCommitmentTree`,
   `L2GlobalInteropRootImporter`, `AtomicFlowEscrow`, then `tree.initialize(escrow)`,
   `importer.initialize(supplier)`, `escrow.initialize(tree, importer)`.
2. **Authorize** the root submitter on L1: `GlobalInteropIMT.setGlobalSubmitter(operator, true)`
   (or `setSubmitter(chainId, executorOrOperator, true)`), and authorize the `supplier` EOA on each
   importer at init.
3. **Commit**: each payer approves the escrow's token and calls `commitPart(flowId, leg)`.
4. **Expose**: the operator calls `GlobalInteropIMT.submitChainRoot(chainId, batchNumber, tree.root(),
   daCommitment)` for each chain (in the real flow this happens automatically from the `Executor` on
   batch execute once the chain opts in via `Admin.setGlobalInteropImt`).
5. **Import**: run `imt-supplier.ts` to copy the global root(s) into each L2 importer.
6. **Finalize / refund**: build the proof JSON with `imt-engine.ts` and submit it to
   `AtomicFlowEscrow.finalize` / `refund` (e.g. via `cast send`, passing the proof fields).

> The Foundry integration test in §2.2 performs exactly this sequence in‑process and is the
> recommended way to see the full flow end‑to‑end without standing up multiple chains.
