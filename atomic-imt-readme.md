# Atomic interop without L1 coordination (Indexed-Merkle-Tree based)

This document explains the **architecture** of the L1‑free atomic interop feature and gives
**hands‑on instructions** for trying it out.

It is the advanced counterpart of the L1‑coordinated `dummy-interop` stack
(`l1-contracts/contracts/dummy-interop`, `L1FlowLinker` + `L2FlowEscrow`). The difference: there is
**no central L1 coordinator**. Flows finalize purely from Merkle proofs against an Indexed Merkle
Tree (IMT) of "parts done" that each chain exposes on L1 and that L2s re‑import.

- Contracts: `l1-contracts/contracts/atomic-interop/` (and its `README.md`).
- Tests: `l1-contracts/test/foundry/l1/unit/concrete/AtomicInterop/`.
- Tooling: `l1-contracts/test/anvil-interop/imt-engine.ts`, `imt-supplier.ts`.

---

## 1. Architecture

### 1.1 The idea in one paragraph

Each chain keeps an **Indexed Merkle Tree** of "parts done". When a participant does their part, the
leg's commit value is inserted; each leaf stores `{value, nextValue, nextIndex}` pointers forming a
sorted linked list, which makes both membership and **non‑membership** provable in O(log n). When the
chain settles a batch, its current IMT root (plus a DA commitment to the tree's preimage) is exposed
on L1 and folded into a **global IMT** that aggregates every chain's root; L1 also appends the new
global root to an **append‑only history tree**. L2s re‑import the historical global root. To
**finalize**, anyone proves — against an imported global root whose L1 timestamp is `≤ deadline` —
that _every_ leg of the flow was committed in time. To **refund** after a timeout, anyone gives an
O(log n) non‑inclusion proof that a leg is absent across the deadline boundary. No L1 contract ever
"authorizes" settlement; it only stores roots.

### 1.2 Components

```
        L2 chain A                         L1                         L2 chain B
  ┌────────────────────┐         ┌──────────────────────┐      ┌────────────────────┐
  │ AtomicFlowEscrow A  │         │  GlobalInteropIMT     │      │ AtomicFlowEscrow B  │
  │  commitPart ────────┼──┐      │  (1) in-place global  │   ┌──┼ commitPart         │
  │  finalize           │  │      │      tree: chain→root │   │  │ finalize           │
  │  refund             │  │      │  (2) append-only      │   │  │ refund             │
  └─────────┬──────────┘  │      │      history tree:    │   │  └─────────┬──────────┘
            │ insert(v,    │      │      (blk,ts,root)    │   │            │ insert(v, lowNull)
            │   lowNull)   │      │  + map root→block     │   │            ▼
            ▼              │      └───────────▲───────────┘   │  ┌────────────────────┐
  ┌────────────────────┐  │ submitChainRoot   │ submitChainRoot           │ L2InteropCommitment │
  │ L2InteropCommitment │  └──(Executor on────┘──(Executor on─────────────│ Tree B (Indexed MT) │
  │ Tree A (Indexed MT) │       batch execute)      batch execute)        └────────────────────┘
  └────────────────────┘                                                            ▲
            ▲                       │ historical global root                        │
            │                       ▼  (imt-supplier)                               │
  ┌────────────────────┐   ┌──────────────────────────┐            ┌────────────────────┐
  │ L2GlobalInterop-    │◄──┤  imt-supplier.ts          ├───────────►│ L2GlobalInterop-   │
  │ RootImporter A      │   │  (trusted: reads L1,      │            │ RootImporter B     │
  └────────────────────┘   │   imports to each L2)     │            └────────────────────┘
                           └──────────────────────────┘
   imt-engine.ts computes commit values, low-nullifier indices, and O(log n) inclusion /
   non-inclusion proofs for finalize / refund.
```

| Contract                       | Layer | Role                                                                                                                                                                                                                                                                                               |
| ------------------------------ | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GlobalInteropIMT`             | L1    | **Two** trees: an in‑place `FullMerkle` global tree (leaf updated per chain) whose root is `globalRoot`, and an append‑only `DynamicIncrementalMerkle` history tree of `keccak256(block, timestamp, globalRoot)` snapshots whose root is `historyRoot`. Plus `mapping(globalRoot => blockNumber)`. |
| `L2InteropCommitmentTree`      | L2    | Per‑chain **Indexed Merkle Tree** (`FullMerkle`‑backed); leaves `{value, nextValue, nextIndex}` form a sorted linked list.                                                                                                                                                                         |
| `L2GlobalInteropRootImporter`  | L2    | Stores global roots imported from L1, keyed by L1 block number + timestamp.                                                                                                                                                                                                                        |
| `AtomicFlowEscrow`             | L2    | `commitPart` / `finalize` / `refund`. State per `(flowId, specHash)`: `Unset → Committed → Finalized` (happy) or `→ Refunded` (timeout).                                                                                                                                                           |
| `libraries/AtomicInteropProof` | both  | Pure O(log n) inclusion and low‑nullifier non‑inclusion verification.                                                                                                                                                                                                                              |

### 1.3 The Indexed Merkle Tree

A leaf is `{ value, nextValue, nextIndex }`. The tree is seeded with a head leaf `{0, 0, 0}` at index 0. Inserting `v`:

1. find the **low‑nullifier** leaf `L` with `L.value < v` and (`L.nextValue == 0` or `v < L.nextValue`);
2. append a new leaf `{ v, L.nextValue, L.nextIndex }`;
3. repoint `L` to `{ L.value, v, newIndex }`.

This keeps the leaves a sorted singly‑linked list over the append‑only array. Consequences:

- **Membership** of `v`: a normal Merkle path to the leaf whose `value == v`.
- **Non‑membership** of `v`: a Merkle path to the single low‑nullifier leaf bracketing `v`
  (`L.value < v < L.nextValue`). O(log n) — no need to disclose the whole leaf set.

The escrow caller (or the IMT engine) supplies the low‑nullifier index to `commitPart`; if the tree
changed since it was computed, the insert reverts and the caller retries with a refreshed index.

### 1.4 Identifiers and values

- `specHash = keccak256(abi.encode(leg))`, `FlowLeg = { chainId, token, amount, payer, payee }`.
- `flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))` — both arrays strictly
  ascending.
- Commit value inserted into a chain's IMT:
  `uint256(keccak256(abi.encode(TAG, flowId, specHash)))`, `TAG = bytes4(keccak256("AtomicInterop.commit.v1"))`.
- Indexed‑leaf hash: `keccak256(abi.encode(value, nextValue, nextIndex))`.
- Global‑tree leaf for a chain: `keccak256(abi.encodePacked(chainImtRoot, chainId))`.
- History‑tree leaf: `keccak256(abi.encode(block, timestamp, globalRoot))`.
- Empty/zero leaf for every tree: `bytes32(0)`.

### 1.5 Lifecycle

1. **Create flow** (off‑chain): legs, `specHash`es, `flowId`.
2. **`commitPart(flowId, leg, lowNullifierIndex)`**: payer locks `amount` of `token`; the escrow
   inserts the leg's commit value into the chain's IMT.
3. **Expose on L1**: on batch settlement the operator includes the chain's IMT root + DA commitment
   in the execute data; the `Executor` calls `GlobalInteropIMT.submitChainRoot`, which updates the
   chain's leaf in the global tree, appends `(block, timestamp, globalRoot)` to the history tree, and
   records `mapping[globalRoot] = block`.
4. **Import on L2**: the `imt-supplier` imports the global root into each L2's
   `L2GlobalInteropRootImporter`.
5. **`finalize(flowId, legs, chainIds, deadline, proofs[])`**: inclusion proof per leg (IMT path →
   global path) against an imported global root with timestamp `≤ deadline`; the chain releases its
   leg(s) to the payee.
6. **`refund(flowId, legs, chainIds, deadline, missingLegIndex, proof)`**: low‑nullifier
   non‑inclusion proof for the missing leg, with the chain IMT root identical in a global root
   `≤ deadline` and one `> deadline`; the chain returns its leg(s) to the payer.

### 1.6 Proof layers

**Inclusion** (`ImtInclusionProof`): a leaf with `value == commitValue` at `imtLeafIndex` hashes
(`imtProof`) to `chainImtRoot`, which hashes (`globalProof`) to `importedGlobalRoot`, with
`importedTimestamp ≤ deadline`.

**Non‑inclusion** (`ImtNonInclusionProof`): a low‑nullifier leaf bracketing the value, included in
`chainImtRoot`, with `chainImtRoot` shown inside an imported global root `≤ deadline` (`globalProofG1`)
and one `> deadline` (`globalProofG2`). The identical chain root across the boundary closes the
"inserted just past the deadline / L1 reorg" window.

### 1.7 Executor integration (opt‑in, backward compatible)

New execute‑data encoding version `SUPPORTED_ENCODING_VERSION_EXECUTE_WITH_IMT = 2` carries a
per‑batch `InteropImtExport { imtRoot, daCommitment }` (decoded by
`BatchDecoder.decodeExecuteImtExports`). `ExecutorFacet._exportInteropImtRoots` calls
`GlobalInteropIMT.submitChainRoot` on L1, gated by `ZKChainStorage.globalInteropImt` (set via
`Admin.setGlobalInteropImt`). Chains that do not opt in, or send legacy v1 execute data, behave
**byte‑for‑byte unchanged**.

### 1.8 Trust assumptions / demo simplifications

- **Exposing the IMT root on L1** is trusted to the operator in the demo; in production the IMT root
  is part of the block commitment and the DA commitment covers the IMT preimage.
- **The `imt-supplier`** is a trusted EOA, mirroring how `L2InteropRootStorage`'s bootloader path is
  mocked.
- **Asset mechanics** in `AtomicFlowEscrow` are a self‑custodial lock/release stand‑in for bridge/NTV
  routing; swapping in AR/NTV settlement does not change the proof logic.

---

## 2. Trying it out

### 2.1 Prerequisites

A standard Foundry `forge` is enough for the contracts and the test demo (no zkSync VM needed):

```bash
forge --version   # forge 1.5.x
```

For the off‑chain CLIs you need Node + repo deps (`yarn install` at the repo root). `yarn` enforces
Node ≥ 20; on Node 18 run the TypeScript tools via `npx ts-node ...` directly.

### 2.2 Fastest path — run the demo as a test

The end‑to‑end lifecycle (commit → expose on L1 → import on L2 → finalize, and timeout → refund) is
exercised as a two‑chain scenario (`vm.chainId` simulates two L2s in one EVM):

```bash
cd l1-contracts
forge build
forge test --match-path "test/foundry/l1/unit/concrete/AtomicInterop/*" -vv
```

What the suites demonstrate:

| Test                                                                              | Shows                                                                                                                                                                                                |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AtomicFlowEscrow.t.sol::test_finalize_happyPath_bothLegsSettle`                  | Full happy path: both legs commit (indexed insert with low‑nullifier), roots are exposed to `GlobalInteropIMT`, imported on both L2s, and both escrows finalize from O(log n) inclusion proofs.      |
| `…::test_refund_whenLegMissingAcrossDeadline`                                     | Timeout path: a leg never commits; an O(log n) low‑nullifier non‑inclusion proof across the deadline boundary refunds the payer (the head leaf alone certifies absence on an otherwise‑empty chain). |
| `…::test_refund_revertsIfLegActuallyPresent`                                      | A forged non‑inclusion proof for a present leg is rejected by the low‑nullifier bracket check.                                                                                                       |
| `…::test_finalize_revertsWhenImportedAfterDeadline` / `…_revertsOnFlowIdMismatch` | Finalize guards.                                                                                                                                                                                     |
| `L2InteropCommitmentTree.t.sol`                                                   | Indexed‑tree insert maintains the sorted linked list; inclusion paths verify; low‑nullifier brackets; insert validation (zero value, wrong nullifier, appender).                                     |
| `GlobalInteropIMT.t.sol::test_submitChainRoot_appendsHistoryTree`                 | The append‑only history tree advances and `mapping(globalRoot => block)` is recorded, alongside the in‑place global tree.                                                                            |
| `ExecutorImtExport.t.sol`                                                         | Opt‑in chains export their IMT root to the registry on execute; legacy path leaves it untouched.                                                                                                     |

Run a single scenario with traces:

```bash
forge test --match-test test_refund_whenLegMissingAcrossDeadline -vvvv
```

### 2.3 Using the off‑chain tooling against a live deployment

Build artifacts first (`cd l1-contracts && forge build`), then run from
`l1-contracts/test/anvil-interop/`.

#### IMT engine — values, low‑nullifiers, proofs

```bash
cd l1-contracts/test/anvil-interop

# Commit value for a (flowId, specHash):
npx ts-node imt-engine.ts value --flow-id 0x<flowId> --spec-hash 0x<specHash>

# Low-nullifier index to pass to commitPart when inserting a value:
npx ts-node imt-engine.ts low-nullifier \
  --l2-rpc http://localhost:9545 --tree 0x<L2InteropCommitmentTree> --value 0x<commitValue>

# Full inclusion proof (ImtInclusionProof JSON for AtomicFlowEscrow.finalize):
npx ts-node imt-engine.ts full-proof \
  --l1-rpc http://localhost:8545 --l2-rpc http://localhost:9545 \
  --tree 0x<L2InteropCommitmentTree> --registry 0x<GlobalInteropIMT> \
  --chain-id 271 --value 0x<commitValue> --l1-block <l1BlockWithRoot>

# O(log n) non-inclusion proof (ImtNonInclusionProof JSON for AtomicFlowEscrow.refund):
npx ts-node imt-engine.ts non-inclusion \
  --l1-rpc http://localhost:8545 --l2-rpc http://localhost:9545 \
  --tree 0x<L2InteropCommitmentTree> --registry 0x<GlobalInteropIMT> \
  --chain-id 272 --value 0x<missingValue> \
  --l1-block-before <blockBeforeDeadline> --l1-block-after <blockAfterDeadline>
```

#### IMT supplier — import L1 global roots to L2

```bash
# One-shot: import every recorded L1 global root not yet on this L2.
npx ts-node imt-supplier.ts \
  --l1-rpc http://localhost:8545 --l2-rpc http://localhost:9545 \
  --registry 0x<GlobalInteropIMT> --importer 0x<L2GlobalInteropRootImporter> \
  --pk 0x<supplierPrivateKey>

# Continuous: poll L1 every 5s and import new roots as they appear.
npx ts-node imt-supplier.ts ... --poll 5
```

### 2.4 Sketch of a manual end‑to‑end run

1. **Deploy** on L1: `GlobalInteropIMT(owner)`. On each L2: `L2InteropCommitmentTree`,
   `L2GlobalInteropRootImporter`, `AtomicFlowEscrow`, then `tree.initialize(escrow)`,
   `importer.initialize(supplier)`, `escrow.initialize(tree, importer)`.
2. **Authorize** the submitter on L1 (`setGlobalSubmitter` or `setSubmitter`) and the supplier on each
   importer (at init).
3. **Commit**: for each leg compute its commit value and low‑nullifier index (`imt-engine.ts value` +
   `low-nullifier`), approve the token, and call `commitPart(flowId, leg, lowNullifierIndex)`.
4. **Expose**: `GlobalInteropIMT.submitChainRoot(chainId, batchNumber, tree.root(), daCommitment)`
   for each chain (automatic from the `Executor` once the chain opts in via
   `Admin.setGlobalInteropImt`).
5. **Import**: run `imt-supplier.ts`.
6. **Finalize / refund**: build the proof JSON with `imt-engine.ts` and submit it to
   `AtomicFlowEscrow.finalize` / `refund`.

> The Foundry integration test in §2.2 performs exactly this sequence in‑process and is the
> recommended way to see the full flow end‑to‑end.
