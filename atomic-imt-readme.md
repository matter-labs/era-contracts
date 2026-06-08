# Atomic interop without L1 coordination (Indexed-Merkle-Tree based)

This document explains the **architecture** of the L1‑free atomic interop feature and gives
**hands‑on instructions** for trying it out.

It is the advanced counterpart of the L1‑coordinated `dummy-interop` stack
(`l1-contracts/contracts/dummy-interop`, `L1FlowLinker` + `L2FlowEscrow`). It keeps that stack's
`SendSpec` / `SpecState` model and asset routing (burn on source, mint on destination via the asset
router + native token vault), but there is **no central L1 coordinator**: authorization is gated by
Indexed Merkle Tree (IMT) proofs against a global interop‑IMT that each chain exposes on L1 and that
L2s re‑import.

- Contracts: `l1-contracts/contracts/atomic-interop/` (and its `README.md`).
- Tests: `l1-contracts/test/foundry/l1/unit/concrete/AtomicInterop/`.
- Tooling: `l1-contracts/test/anvil-interop/{imt-engine,imt-supplier,atomic-flow-cli}.ts`.

---

## 1. Architecture

### 1.1 The idea in one paragraph

Each chain keeps an **Indexed Merkle Tree** of "parts done". `commitSend` locks the source tokens
and inserts the leg's commit value; each leaf stores `{value, nextValue, nextIndex}` pointers
forming a sorted linked list, which makes membership and **non‑membership** provable in O(log n).
On batch settlement the chain's `Executor` (its diamond proxy) exposes the IMT root on L1 into the
**global IMT** (an in‑place tree aggregating every chain's root), and L1 appends the new global root
to an **append‑only history tree**. L2s re‑import the historical global root. To **authorize** a
flow, anyone proves — against an imported global root with L1 timestamp `≤ deadline` — that _every_
leg was committed in time; the relevant specs become `Executable` and `execute` performs the
burn/mint through AR/NTV. To **refund** after a timeout, anyone gives an O(log n) non‑inclusion proof
that a leg is absent across the deadline boundary. No L1 contract authorizes settlement; it only
stores roots.

### 1.2 Components

```
        L2 chain A                         L1                         L2 chain B
  ┌────────────────────┐         ┌──────────────────────┐      ┌────────────────────┐
  │ AtomicFlowEscrow A  │         │  GlobalInteropIMT     │      │ AtomicFlowEscrow B  │
  │  commitSend ────────┼──┐      │  (1) in-place global  │   ┌──┼ commitSend         │
  │  authorize          │  │      │      tree: chain→root │   │  │ authorize          │
  │  execute (AR/NTV)   │  │      │  (2) append-only      │   │  │ execute (AR/NTV)   │
  │  authorizeRefund    │  │      │      history tree     │   │  │ authorizeRefund    │
  │  claimRefund        │  │      │  submitter = chain's  │   │  │ claimRefund        │
  └─────────┬──────────┘  │      │  diamond (Bridgehub)  │   │  └─────────┬──────────┘
            │ insert(v,    │      └───────────▲───────────┘   │            │ insert(v, lowNull)
            │   lowNull)   │  submitChainRoot  │ submitChainRoot           ▼
            ▼              │  (Executor=diamond)│ (Executor=diamond)  ┌────────────────────┐
  ┌────────────────────┐  └────────────────────┘─────────────────────│ L2InteropCommitment │
  │ L2InteropCommitment │                                            │ Tree B (Indexed MT) │
  │ Tree A (Indexed MT) │      historical global root (imt-supplier) └────────────────────┘
  └────────────────────┘                  │                                    ▲
            ▲                              ▼                                    │
  ┌────────────────────┐   ┌──────────────────────────┐            ┌────────────────────┐
  │ L2GlobalInterop-    │◄──┤  imt-supplier.ts          ├───────────►│ L2GlobalInterop-   │
  │ RootImporter A      │   │  (reads L1, imports to L2)│            │ RootImporter B     │
  └────────────────────┘   └──────────────────────────┘            └────────────────────┘
   imt-engine.ts: commit values, low-nullifier indices, O(log n) inclusion / non-inclusion proofs.
   atomic-flow-cli.ts: interactive register / commit / check-status / finalize over a JSON file.
```

| Contract                       | Layer | Role                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------ | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GlobalInteropIMT`             | L1    | In‑place `FullMerkle` global tree (`globalRoot`) + append‑only `DynamicIncrementalMerkle` history tree (`historyRoot`) + `mapping(globalRoot => block)`. Submitter for a chain = its diamond proxy (from the **Bridgehub**), or a temporary owner‑authorized **global submitter** stub (demo relayer). Batch numbers strictly consecutive. |
| `L2InteropCommitmentTree`      | L2    | Per‑chain **Indexed Merkle Tree**; leaves `{value, nextValue, nextIndex}`.                                                                                                                                                                                                                                                                 |
| `L2GlobalInteropRootImporter`  | L2    | Stores global roots imported from L1 (L1 block + timestamp).                                                                                                                                                                                                                                                                               |
| `AtomicFlowEscrow`             | L2    | `commitSend` / `authorize` / `execute` / `authorizeRefund` / `claimRefund`. `SpecState`: `Unset → Committed → Executable → Executed` or `Committed → Revertable → Reverted`. AR/NTV asset routing.                                                                                                                                         |
| `libraries/AtomicInteropProof` | both  | O(log n) inclusion and low‑nullifier non‑inclusion verification.                                                                                                                                                                                                                                                                           |

### 1.3 The Indexed Merkle Tree

A leaf is `{value, nextValue, nextIndex}`, seeded with a head leaf `{0,0,0}` at index 0. Inserting
`v`: find the **low‑nullifier** leaf `L` with `L.value < v` and (`L.nextValue == 0` or
`v < L.nextValue`); append `{v, L.nextValue, L.nextIndex}`; repoint `L`. Membership of `v` is a path
to the leaf whose `value == v`; non‑membership is a path to the single low‑nullifier leaf bracketing
`v`. The caller supplies the low‑nullifier index to `commitSend` (from the IMT engine).

### 1.4 Identifiers and values

- `SendSpec = {destChainId, recipient, originChainId, originToken, amount, erc20Data, depositor}`;
  `specHash = keccak256(abi.encode(spec))`.
- `flowId = keccak256(abi.encode(sortedSpecHashes, sortedChainIds, deadline))`.
- Commit value: `uint256(keccak256(abi.encode(TAG, flowId, specHash)))`,
  `TAG = bytes4(keccak256("AtomicInterop.commit.v1"))`.
- Indexed‑leaf hash: `keccak256(abi.encode(value, nextValue, nextIndex))`.
- Global‑tree leaf: `keccak256(abi.encodePacked(chainImtRoot, chainId))`.
- History‑tree leaf: `keccak256(abi.encode(block, timestamp, globalRoot))`.

### 1.5 Lifecycle

1. **Create flow** (off‑chain): specs, `specHash`es, `flowId`.
2. **`commitSend(flowId, spec, lowNullifierIndex)`** on the origin chain: lock + IMT insert.
3. **Expose on L1**: the chain's `Executor` (diamond) calls `GlobalInteropIMT.submitChainRoot`.
4. **Import on L2**: `imt-supplier` imports the global root into each L2 importer.
5. **`authorize(flowId, specs, chainIds, deadline, proofs)`**: inclusion proof per spec → specs on
   this chain become `Executable`.
6. **`execute(flowId, spec)`**: source burn / destination mint via AR/NTV.
7. **`authorizeRefund(flowId, specs, chainIds, deadline, missingSpecIndex, proof)` + `claimRefund`**:
   the timeout path.

### 1.6 Executor integration (opt‑in, backward compatible)

New execute‑data encoding version `SUPPORTED_ENCODING_VERSION_EXECUTE_WITH_IMT = 2` carries a
per‑batch `InteropImtExport { imtRoot }`. `ExecutorFacet._exportInteropImtRoots` calls
`GlobalInteropIMT.submitChainRoot(chainId, batchNumber, imtRoot)`. Because the call comes from the
diamond proxy, it satisfies the registry's "submitter == Bridgehub.getZKChain(chainId)" check. Gated
by `ZKChainStorage.globalInteropImt` (set via `Admin.setGlobalInteropImt`); chains that do not opt in,
or send legacy v1 execute data, behave byte‑for‑byte unchanged.

### 1.7 Trust assumptions / demo simplifications

- Exposing the IMT root on L1 is operator‑trusted in the demo (submitted by the chain's diamond); in
  production the IMT root is part of the block commitment.
- The `imt-supplier` is a trusted EOA, mirroring how `L2InteropRootStorage`'s bootloader path is mocked.
- The AR/NTV asset mechanics match `L2FlowEscrow`; the Foundry unit tests mock the asset router to
  isolate the escrow's proof‑gating + state machine.

---

## 2. Trying it out

### 2.1 Prerequisites

A standard Foundry `forge` is enough for the contracts and the test demo. For the off‑chain CLIs you
need Node + repo deps (`yarn install`); on Node 18 run the TS tools via `npx ts-node ...` directly.

### 2.2 Fastest path — run the demo as a test

```bash
cd l1-contracts
forge build
forge test --match-path "test/foundry/l1/unit/concrete/AtomicInterop/*" -vv
```

What the suites demonstrate:

| Test                                                                                                                            | Shows                                                                                                                                                                           |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AtomicFlowEscrow.t.sol::test_happyPath_commitAuthorizeExecute`                                                                 | Two‑leg swap: `commitSend` (indexed insert), expose roots, import, `authorize` (O(log n) inclusion), `execute` (source burn / dest mint via the mock AR on both chains).        |
| `…::test_refund_whenLegMissingAcrossDeadline`                                                                                   | Timeout: a leg never commits; an O(log n) low‑nullifier non‑inclusion proof across the deadline boundary marks the source spec `Revertable` and `claimRefund` returns the lock. |
| `…::test_authorizeRefund_revertsIfLegActuallyPresent`                                                                           | A forged non‑inclusion proof for a present leg is rejected by the low‑nullifier bracket.                                                                                        |
| `…::test_authorize_revertsWhenImportedAfterDeadline`, `…::test_execute_revertsWhenNotAuthorized`, `…::test_commitSend_reverts*` | Guards.                                                                                                                                                                         |
| `L2InteropCommitmentTree.t.sol`                                                                                                 | Indexed‑tree insert / linked list / low‑nullifier / inclusion paths.                                                                                                            |
| `GlobalInteropIMT.t.sol`                                                                                                        | Bridgehub‑gated submitter, in‑place + history trees, strictly‑consecutive batches.                                                                                              |
| `ExecutorImtExport.t.sol`                                                                                                       | Opt‑in chains export their IMT root to the registry on execute (submitted by the diamond); legacy path untouched.                                                               |

### 2.3 Off‑chain tooling against a live deployment

Build artifacts first (`forge build`), then run from `l1-contracts/test/anvil-interop/`.

```bash
# Commit value for a (flowId, specHash):
npx ts-node imt-engine.ts value --flow-id 0x<flowId> --spec-hash 0x<specHash>
# Low-nullifier index to pass to commitSend:
npx ts-node imt-engine.ts low-nullifier --l2-rpc <url> --tree 0x<tree> --value 0x<commitValue>
# Inclusion proof (ImtInclusionProof JSON for authorize):
npx ts-node imt-engine.ts full-proof --l1-rpc <url> --l2-rpc <url> --tree 0x<tree> \
    --registry 0x<GlobalInteropIMT> --chain-id 271 --value 0x<commitValue> --l1-block <n>
# Non-inclusion proof (ImtNonInclusionProof JSON for authorizeRefund):
npx ts-node imt-engine.ts non-inclusion --l1-rpc <url> --l2-rpc <url> --tree 0x<tree> \
    --registry 0x<GlobalInteropIMT> --chain-id 272 --value 0x<value> \
    --l1-block-before <n> --l1-block-after <n>

# Import L1 global roots to an L2 (one-shot, or --poll <seconds>):
npx ts-node imt-supplier.ts --l1-rpc <url> --l2-rpc <url> \
    --registry 0x<GlobalInteropIMT> --importer 0x<importer> --pk 0x<supplierPk>
```

#### Root relayer — expose + supply in one process

`atomic-root-relayer.ts` automates the whole "expose roots to L1 + supply global roots back to each
L2" loop with a single private key (the relayer must be authorized via `setGlobalSubmitter` and be
each importer's supplier). It takes a JSON config listing the L2 chains (rpc / tree / importer) and
the L1 connection:

```bash
# relayer.json: { "l1Rpc", "registry", "privateKey", "chains": [{chainId, rpc, tree, importer}, ...] }
npx ts-node atomic-root-relayer.ts --config relayer.json
npx ts-node atomic-root-relayer.ts --config relayer.json --l1-rpc <url> --pk 0x<key> --poll 5
```

### 2.4 Interactive demo (`atomic-flow-cli.ts`)

A JSON‑backed walk‑through of a two‑leg swap. The state file (`atomic-flow-state.json`, override with
`--state`) holds a `config` section you fill with deployed addresses (L1 `registry`, and per‑chain
`rpc` / `escrow` / `tree` / `importer`), and the registered flows.

```bash
cd l1-contracts/test/anvil-interop

# Define the swap (interactive prompts; or --default for the built-in pair). Auto-resolves leg ids
# (specHash) and the flowId and saves them.
npx ts-node atomic-flow-cli.ts register-flow-id
npx ts-node atomic-flow-cli.ts register-flow-id --default --deadline <unix>

npx ts-node atomic-flow-cli.ts list-flows
npx ts-node atomic-flow-cli.ts flow-info <flowId>          # legs with their hashes + infos

# Each signer does their part on the leg's origin chain:
npx ts-node atomic-flow-cli.ts commit-send <flowId> <legId> <privateKey> <rpcUrl>

# Whether all legs are committed on their L2s:
npx ts-node atomic-flow-cli.ts check-status <flowId>

# Authorize the flow (builds inclusion proofs for all legs) and execute the given leg:
npx ts-node atomic-flow-cli.ts finalize <flowId> <legId> <privateKey> <rpcUrl>
```

> Exposing roots on L1 (`submitChainRoot`) and importing them to L2 (`imt-supplier`) happen out of
> band between `commit-send` and `finalize` — in a real deployment automatically via the `Executor`
> and the supplier. The Foundry integration test in §2.2 performs the whole sequence in‑process.
