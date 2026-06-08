# Atomic interop without L1 coordination (Indexed-Merkle-Tree based)

This document explains the **architecture** of the L1‑free atomic interop feature and gives
**hands‑on instructions** for trying it out against the local **two‑Anvil mock** setup.

> **Running it on real ZKsync OS servers?** See
> [`atomic-imt-server-demo.md`](./atomic-imt-server-demo.md) — the end‑to‑end runbook that
> bootstraps two `zksync-os-server` chains with `zk-deployer`, **starts Anvil + both servers**,
> deploys the L1 `GlobalInteropIMT`, and drives the flow with the relayer + flow CLI. The
> server‑startup steps live there (§3).

It is the advanced counterpart of the L1‑coordinated `dummy-interop` stack
(`l1-contracts/contracts/dummy-interop`, `L1FlowLinker` + `L2FlowEscrow`). It keeps that stack's
`SendSpec` / `SpecState` model and asset routing (burn on source, mint on destination via the asset
router + native token vault), but there is **no central L1 coordinator**: authorization is gated by
Indexed Merkle Tree (IMT) proofs against a global interop‑IMT that each chain exposes on L1 and that
L2s re‑import. There are **no changes to the `Executor` or any core protocol contract** — roots are
relayed permissionlessly.

- Contracts: `l1-contracts/contracts/atomic-interop/` (and its `README.md`).
- Tests: `l1-contracts/test/foundry/l1/unit/concrete/AtomicInterop/`.
- Tooling: `l1-contracts/test/anvil-interop/{imt-engine,imt-supplier,atomic-root-relayer,atomic-flow-cli}.ts`.

---

## 1. Architecture

### 1.1 The idea in one paragraph

Each chain keeps an **Indexed Merkle Tree** of "parts done". `commitSend` locks the source tokens
and inserts the leg's commit value; each leaf stores `{value, nextValue, nextIndex}` pointers
forming a sorted linked list, which makes membership and **non‑membership** provable in O(log n).
On batch settlement the chain's IMT root is exposed on L1 into the **global IMT** (an in‑place tree
aggregating every chain's root), and L1 appends the new global root to an **append‑only history
tree**. L2s re‑import the historical global root. To **authorize** a flow, anyone proves — against an
imported global root with L1 timestamp `≤ deadline` — that _every_ leg was committed in time (a leg
committed on the verifying chain itself needs no proof, just its local state); the relevant specs
become `Executable` and `execute` performs the burn/mint through AR/NTV. To **refund** after a
timeout, anyone gives an O(log n) non‑inclusion proof. No contract authorizes settlement; L1 only
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
  │  claimRefund        │  │      │  submit: permissionless│  │  │ claimRefund        │
  └─────────┬──────────┘  │      │  (stub; chainDiamond   │   │  └─────────┬──────────┘
            │ insert(v,    │      │   preserved)          │   │            │ insert(v, lowNull)
            │   lowNull)   │      └───────────▲───────────┘   │            ▼
            ▼              │     submitChainRoot │ (relayer / anyone)  ┌────────────────────┐
  ┌────────────────────┐  └─────────────────────┴────────────────────│ L2InteropCommitment │
  │ L2InteropCommitment │                                            │ Tree B (Indexed MT) │
  │ Tree A (Indexed MT) │     historical global root (relayer/supplier) └──────────────────┘
  └────────────────────┘                  │                                    ▲
            ▲                              ▼                                    │
  ┌────────────────────┐   ┌──────────────────────────┐            ┌────────────────────┐
  │ L2GlobalInterop-    │◄──┤ atomic-root-relayer.ts /  ├───────────►│ L2GlobalInterop-   │
  │ RootImporter A      │   │ imt-supplier.ts           │            │ RootImporter B     │
  └────────────────────┘   └──────────────────────────┘            └────────────────────┘
   imt-engine.ts: commit values, low-nullifier indices, O(log n) inclusion / non-inclusion proofs.
   atomic-flow-cli.ts: interactive register / commit / check-status / finalize over a JSON file.
```

| Contract                       | Layer | Role                                                                                                                                                                                                                                                                                                                 |
| ------------------------------ | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GlobalInteropIMT`             | L1    | In‑place `FullMerkle` global tree (`globalRoot`) + append‑only `DynamicIncrementalMerkle` history tree (`historyRoot`) + `mapping(globalRoot => block)`. `submitChainRoot` is a permissionless stub; `chainDiamond` (Bridgehub lookup) is preserved to re‑enable access control. Batch numbers strictly consecutive. |
| `L2InteropCommitmentTree`      | L2    | Per‑chain **Indexed Merkle Tree**; leaves `{value, nextValue, nextIndex}`.                                                                                                                                                                                                                                           |
| `L2GlobalInteropRootImporter`  | L2    | Stores global roots imported from L1 (permissionless stub).                                                                                                                                                                                                                                                          |
| `AtomicFlowEscrow`             | L2    | `commitSend` / `authorize` / `execute` / `authorizeRefund` / `claimRefund`. `SpecState`: `Unset → Committed → Executable → Executed` or `Committed → Revertable → Reverted`. AR/NTV asset routing.                                                                                                                   |
| `libraries/AtomicInteropProof` | both  | O(log n) inclusion and low‑nullifier non‑inclusion verification.                                                                                                                                                                                                                                                     |

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
3. **Expose on L1**: anyone (the relayer) calls `GlobalInteropIMT.submitChainRoot(chainId, batch, root)`.
4. **Import on L2**: the relayer/supplier imports the global root into each L2 importer.
5. **`authorize(flowId, specs, chainIds, deadline, proofs)`**: inclusion proof for each _remote_ spec
   (local‑origin specs are checked via state) → specs on this chain become `Executable`.
6. **`execute(flowId, spec)`**: source burn / destination mint via AR/NTV.
7. **`authorizeRefund(...)` + `claimRefund(...)`**: the timeout path.

### 1.6 ZKsync OS genesis integration

The three L2 contracts are predeployed in the ZKsync OS genesis (no `Executor`/core changes):

- registered in `tools/zksync-os-genesis-gen/src/consts.rs` (`INITIAL_CONTRACTS`, `SystemProxy`) at
  `0x10012` (`L2InteropCommitmentTree`), `0x10013` (`L2GlobalInteropRootImporter`), `0x10014`
  (`AtomicFlowEscrow`); address constants in `common/l2-helpers/L2ContractAddresses.sol`;
- wired in `L2GenesisForceDeploymentsHelper._initializeV31Contracts` (ZKsync OS only): the tree's
  appender → the escrow; the escrow → (tree, importer, asset router, native token vault). The
  importer is permissionless and needs no init.

Regenerate `configs/genesis/zksync-os/latest.json` by running the genesis gen tool after building the
l1-contracts artifacts.

### 1.7 Trust assumptions / demo simplifications

- `submitChainRoot` (L1) and `importGlobalRoot` (L2) are TEMPORARY permissionless stubs. The
  production access models are preserved/documented: a chain's root should be submitted by its
  diamond proxy (`chainDiamond`, from the Bridgehub), and global roots should be delivered to L2 by
  the bootloader (like `L2InteropRootStorage`). The per‑chain "zk chain flow" in the global tree
  (registration + in‑place leaf updates) is independent of the access check and unchanged.
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
| `AtomicFlowEscrow.t.sol::test_happyPath_commitAuthorizeExecute`                                                                 | Two‑leg swap: `commitSend` (indexed insert), expose roots, import, `authorize` (proofs only for remote‑origin specs), `execute` (source burn / dest mint via the mock AR).      |
| `…::test_refund_whenLegMissingAcrossDeadline`                                                                                   | Timeout: a leg never commits; an O(log n) low‑nullifier non‑inclusion proof across the deadline boundary marks the source spec `Revertable` and `claimRefund` returns the lock. |
| `…::test_authorizeRefund_revertsIfLegActuallyPresent`                                                                           | A forged non‑inclusion proof for a present leg is rejected by the low‑nullifier bracket.                                                                                        |
| `…::test_authorize_revertsWhenImportedAfterDeadline`, `…::test_execute_revertsWhenNotAuthorized`, `…::test_commitSend_reverts*` | Guards.                                                                                                                                                                         |
| `L2InteropCommitmentTree.t.sol`                                                                                                 | Indexed‑tree insert / linked list / low‑nullifier / inclusion paths.                                                                                                            |
| `GlobalInteropIMT.t.sol`                                                                                                        | Permissionless submit, in‑place + history trees, `chainDiamond` lookup, strictly‑consecutive batches.                                                                           |
| `L2GlobalInteropRootImporter.t.sol`                                                                                             | Permissionless import + idempotency / conflict guard.                                                                                                                           |

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
    --registry 0x<GlobalInteropIMT> --importer 0x<importer> --pk 0x<key>
```

#### Root relayer — expose + supply in one process

`atomic-root-relayer.ts` automates the whole "expose roots to L1 + supply global roots back to each
L2" loop with a single private key (permissionless, so any key works). It takes a JSON config listing
the L2 chains (rpc / tree / importer) and the L1 connection:

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

# Authorize the flow (builds inclusion proofs for the remote-origin legs) and execute the given leg:
npx ts-node atomic-flow-cli.ts finalize <flowId> <legId> <privateKey> <rpcUrl>
```

> Exposing roots on L1 (`submitChainRoot`) and importing them to L2 happen out of band between
> `commit-send` and `finalize` — run `atomic-root-relayer.ts` (or `imt-supplier.ts`). The Foundry
> integration test in §2.2 performs the whole sequence in‑process.
