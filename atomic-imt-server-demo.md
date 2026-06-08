# Atomic-interop (IMT) end-to-end demo on the ZKsync OS server

This document shows how to run the **L1-free atomic-interop** feature
(`l1-contracts/contracts/atomic-interop/`) on real
[`zksync-os-server`](https://github.com/matter-labs/zksync-os-server) nodes and drive a
two-chain atomic swap through its full lifecycle:

```
commitSend ──▶ per-chain IMT (L2InteropCommitmentTree)
                     │  (root relayed by atomic-root-relayer.ts)
                     ▼
              L1 GlobalInteropIMT  ──aggregate──▶ global root + append-only history
                     │  (global root relayed back)
                     ▼
        L2GlobalInteropRootImporter  ──▶  authorize() verifies the spec's
                                          IMT inclusion proof  ──▶ Executable
```

For the architecture and the contract-level design, see
[`atomic-imt-readme.md`](./atomic-imt-readme.md). This file is purely the **server / e2e**
runbook. Every command below was executed and verified end to end (two ZKsync OS chains
`6565` ⇄ `6566` on a single L1 Anvil).

---

## TL;DR — the one-touch script

The whole runbook is wrapped in [`l1-contracts/test/anvil-interop/atomic-os-demo.sh`](./l1-contracts/test/anvil-interop/atomic-os-demo.sh)
as three repeatable commands. Copy `atomic-os-demo.env.example` to `atomic-os-demo.env` (next to
the script) and set the three tool paths (`ZK_DEPLOYER`, `SERVER_BIN`, `LOCAL_DEV`), then:

```bash
cd l1-contracts/test/anvil-interop

./atomic-os-demo.sh update-server   # forge build + zk-deployer bootstrap/apply + genesis + server configs
./atomic-os-demo.sh launch          # start Anvil + both servers, deploy L1 GlobalInteropIMT,
                                     # fund the rich/relayer wallet via L1->L2, start the relayer daemon
./atomic-os-demo.sh demo            # register a sample swap, commit both legs, wait for relay,
                                     # authorize (verifies the IMT inclusion proof), then try execute

./atomic-os-demo.sh status          # show running processes + key addresses
./atomic-os-demo.sh stop            # tear everything down
```

All three reuse the same constants (RPCs `8545`/`3050`/`3150`, chain ids `6565`/`6566`, the standard
Anvil rich account as deployer/relayer/depositor) and a single work dir (`.atomic-os-demo/`), so they
compose without any manual copy-paste. Each step prints a numbered, colourised progress log. The
sections below explain what each command does, if you want to run it by hand.

---

## What this demo proves

| Step             | Component                                                                  | Result                                                                                                                                |
| ---------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Genesis          | 3 new L2 predeploys (`0x10012` tree, `0x10013` importer, `0x10014` escrow) | deployed **and initialized** at genesis on both chains                                                                                |
| `commitSend`     | `AtomicFlowEscrow` + `L2InteropCommitmentTree`                             | ERC20 escrowed, commit value inserted into the per-chain Indexed Merkle Tree                                                          |
| relay (parallel) | `atomic-root-relayer.ts`                                                   | per-chain IMT root → L1 `GlobalInteropIMT`; global root + history imported back to each chain                                         |
| `authorize`      | `AtomicFlowEscrow`                                                         | **remote** leg verified via IMT **inclusion proof** vs. the imported global root; **local** leg via local state — both → `Executable` |

`execute()` (the AR/NTV token settlement) is intentionally **out of scope** for this
lightweight two-server demo: it needs the standard cross-chain bridge authorisation
(the escrow registered as an authorised deposit finaliser + matching `assetId`s), which is
orthogonal to the IMT coordination layer and is already covered by the 30 Foundry tests in
`l1-contracts/test/foundry/l1/unit/concrete/AtomicInterop/` (which use `MockAtomicAssetRouter`).
On the live chains `execute()` reverts with `Unauthorized(0x…10014)` from the L2 AssetRouter —
expected.

---

## Prerequisites

1. **`zk-deployer`** — the ecosystem bootstrapper from
   `zksync-os-integration-tests`. Point its `protocol_ops` git dependency at this branch
   (`bin/zk-deployer/Cargo.toml` and `tests/Cargo.toml`):

   ```toml
   protocol_ops = { git = "https://github.com/<fork>/era-contracts", branch = "kl/atomic-imt-interop" }
   ```

   Then add the 3 new predeploys to the deployer's genesis contract list
   (`bin/zk-deployer/src/commands/genesis/consts.rs`) — append to `INITIAL_CONTRACTS`
   (bump the array length) and add the address constants:

   ```rust
   const L2_INTEROP_COMMITMENT_TREE: Address     = addr!("0000000000000000000000000000000000010012");
   const L2_GLOBAL_INTEROP_ROOT_IMPORTER: Address = addr!("0000000000000000000000000000000000010013");
   const L2_ATOMIC_FLOW_ESCROW: Address          = addr!("0000000000000000000000000000000000010014");
   // …
   (L2_INTEROP_COMMITMENT_TREE,      ContractDeployment::SystemProxy("L2InteropCommitmentTree")),
   (L2_GLOBAL_INTEROP_ROOT_IMPORTER, ContractDeployment::SystemProxy("L2GlobalInteropRootImporter")),
   (L2_ATOMIC_FLOW_ESCROW,           ContractDeployment::SystemProxy("AtomicFlowEscrow")),
   ```

   Build: `CARGO_PROFILE_DEV_DEBUG=0 cargo build -p zk-deployer -j 2`.

2. **`zksync-os-server`** — see the local-demo patch below. Build the release binary:
   `cargo build --release --bin zksync-os-server -j 4`.

3. **Foundry** (`anvil`, `cast`, `forge`) and the repo's TypeScript deps (`yarn` already
   installed in `era-contracts`).

4. Build the L1 artifacts so the deployer and the TS scripts can load ABIs/bytecode:
   `cd l1-contracts && forge build`.

### The local-demo server patch

The pre-built airbender proving stack in a local `zksync-os-server` checkout can pull two
incompatible airbender tags (`v0.4.3` + `v0.5.2`), so real witness generation panics
(`CSR number 3072 not supported`). Real proving is **not** needed for this demo, and the
fake FRI/SNARK provers ignore the witness. A one-line, env-gated bypass in
`node/bin/src/prover_input_generator/mod.rs` makes `compute_prover_input` return an empty
input when `ZKSYNC_OS_DEMO_SKIP_PROVING` is set:

```rust
fn compute_prover_input(/* … */) -> Vec<u32> {
    if std::env::var_os("ZKSYNC_OS_DEMO_SKIP_PROVING").is_some() {
        return Vec::new();
    }
    // … original body …
}
```

With this, every block still flows to the batcher (no pipeline starvation) and batches
**commit / prove / execute** on L1 with fake proofs. Combined with **validium DA**
(below) the whole node stays healthy without a working prover.

---

## 1. Bootstrap a two-chain ecosystem (validium / no-DA)

`intent.yaml` — two L1-settling ZKsync OS chains. **`da_mode: no_da`** matters: it wires the
no-DA L1 validator so batches commit with empty DA (no blobs / no real witness needed).

```yaml
schema_version: 1
scenario: l1_only
wallets: { generate: true, ecosystem_seed: "atomic-interop-demo" }
ecosystem: { era_chain_id: 6565, vm_type: zksyncos, with_testnet_verifier: true, with_legacy_bridge: false }
chains:
  - { name: chain-a, chain_id: 6565, role: l1_settling, base_token: eth, da_mode: no_da, skip_priority_txs: true }
  - { name: chain-b, chain_id: 6566, role: l1_settling, base_token: eth, da_mode: no_da, skip_priority_txs: true }
```

```bash
export PROTOCOL_CONTRACTS_ROOT=/path/to/era-contracts
ZK=/path/to/zksync-os-integration-tests/target/debug/zk-deployer

$ZK bootstrap --broadcast                       # deploys Bridgehub/CTM + genesis (auto-Anvil)
$ZK apply --broadcast                            # registers chain-a and chain-b
$ZK server-config --chain chain-a --output chainA.yaml
$ZK server-config --chain chain-b --output chainB.yaml
```

Verify the 3 predeploys are in the generated genesis:

```bash
for a in 10012 10013 10014; do grep -c "00000000000000000000000000000000000$a" genesis.json; done   # → 2 each
```

> **Note on `execution_version`.** The newer server requires a top-level
> `execution_version` field in `genesis.json`. The genesis template
> (`configs/genesis/zksync-os/latest.json`) now carries `"execution_version": 5`, which the
> deployer round-trips into the generated genesis.

## 2. Configure server ports + pubdata mode

Both server configs must use **`pubdata_mode: Validium`** (matches the no-DA L1 pricing mode;
also skips the blob pubdata path that an empty prover input would underflow). Edit both:

```bash
sed -i 's/pubdata_mode: .*/pubdata_mode: Validium/' chainA.yaml chainB.yaml
```

Give chain-b distinct ports (append to `chainB.yaml`):

```yaml
rpc: { address: "0.0.0.0:3150" }
prover_api: { address: "0.0.0.0:3224" }
status_server: { address: "0.0.0.0:3171" }
observability: { prometheus: { port: 3412 }, log: { format: terminal, use_color: true } }
```

## 3. Start Anvil + both servers

```bash
anvil --load-state l1-state.json --block-time 0.25 --mixed-mining \
      --slots-in-an-epoch 10 --disable-block-gas-limit --port 8545 &

SERVER=/path/to/zksync-os-server/target/release/zksync-os-server
LOCAL_DEV=/path/to/zksync-os-integration-tests/tests/configs/local_dev.yaml

ZKSYNC_OS_DEMO_SKIP_PROVING=1 L1_PROVIDER_RPC_URL=http://127.0.0.1:8545 \
  $SERVER --config $LOCAL_DEV --config chainA.yaml &     # RPC :3050
ZKSYNC_OS_DEMO_SKIP_PROVING=1 L1_PROVIDER_RPC_URL=http://127.0.0.1:8545 \
  $SERVER --config $LOCAL_DEV --config chainB.yaml &     # RPC :3150
```

Sanity (both chains): the predeploys are deployed **and initialized** by the genesis upgrade:

```bash
cast call 0x0000000000000000000000000000000000010014 'commitmentTree()(address)' --rpc-url http://127.0.0.1:3050
# → 0x…10012   (escrow wired to tree; importer()/assetRouter()/nativeTokenVault() likewise)
cast call 0x0000000000000000000000000000000000010012 'appender()(address)'      --rpc-url http://127.0.0.1:3050
# → 0x…10014   (tree's only appender is the escrow)
```

## 4. Deploy the L1 registry + fund / set up tokens

`GlobalInteropIMT` is **not** part of the ecosystem bootstrap — deploy it on L1, pointing at
the bridgehub printed by `bootstrap`:

```bash
cd l1-contracts
forge create contracts/atomic-interop/GlobalInteropIMT.sol:GlobalInteropIMT \
  --rpc-url http://127.0.0.1:8545 --private-key $PK --broadcast \
  --constructor-args <BRIDGEHUB>
# verify: cast call <REG> 'chainDiamond(uint256)(address)' 6565   → chain-a diamond
```

Fund L2 accounts via L1→L2 deposits (the running server's `l1_watcher` credits them — no
manual relay):

```bash
cd test/anvil-interop
npx ts-node fund-l2.ts --l1-rpc http://127.0.0.1:8545 --l2-rpc http://127.0.0.1:3050 \
    --bridgehub <BRIDGEHUB> --chain-id 6565 --recipient 0xf39F…2266 --amount 1000
# …repeat for chain-b (:3150, chain-id 6566)
```

Deploy a demo ERC20 on each chain (ZKsync OS runs EVM, so `forge create` works), mint to the
depositor and approve the escrow `0x…10014`:

```bash
forge create contracts/dev-contracts/TestnetERC20Token.sol:TestnetERC20Token \
  --rpc-url http://127.0.0.1:3050 --private-key $PK --broadcast \
  --constructor-args "DemoToken" "DEMO" 18
cast send <TOKEN_A> 'mint(address,uint256)'    0xf39F…2266 1000000000000000000000 --rpc-url http://127.0.0.1:3050 --private-key $PK
cast send <TOKEN_A> 'approve(address,uint256)' 0x…10014    1000000000000000000000 --rpc-url http://127.0.0.1:3050 --private-key $PK
# …repeat on chain-b (:3150)
```

## 5. Run the root relayer (in parallel)

`relayer.json`:

```json
{
  "l1Rpc": "http://127.0.0.1:8545",
  "registry": "<GlobalInteropIMT>",
  "privateKey": "0xac09…ff80",
  "chains": [
    { "chainId": 6565, "rpc": "http://127.0.0.1:3050", "tree": "0x…10012", "importer": "0x…10013" },
    { "chainId": 6566, "rpc": "http://127.0.0.1:3150", "tree": "0x…10012", "importer": "0x…10013" }
  ]
}
```

Run it as a continuous daemon alongside the chains (the production stand-in for each chain's
own root submission + bootloader delivery):

```bash
npx ts-node atomic-root-relayer.ts --config relayer.json --poll 5
# [relayer] exposed chain 6565 root 0x… as batch N (tx …)
# [relayer] imported global root 0x… (L1 block …) into chain 6565
# [relayer] polling every 5s...
```

## 6. Drive the swap with the flow CLI

`atomic-flow-state.json` holds the deployed addresses; register the two legs from a JSON file
(non-interactive `--legs-file`, added for scripted demos):

```bash
cat > legs.json <<'JSON'
[
  { "originChainId": 6565, "depositor": "0xf39F…2266", "originToken": "<TOKEN_A>", "amount": "100",
    "destChainId": 6566, "recipient": "0x7099…79C8", "erc20Data": "0x" },
  { "originChainId": 6566, "depositor": "0xf39F…2266", "originToken": "<TOKEN_B>", "amount": "50",
    "destChainId": 6565, "recipient": "0x7099…79C8", "erc20Data": "0x" }
]
JSON

CLI="npx ts-node atomic-flow-cli.ts --state atomic-flow-state.json"
$CLI register-flow-id --legs-file legs.json          # → prints flowId + per-leg legId
$CLI commit-send <flowId> <legId-A> $PK http://127.0.0.1:3050   # commit leg A on chain-a
$CLI commit-send <flowId> <legId-B> $PK http://127.0.0.1:3150   # commit leg B on chain-b

# let the relayer expose the post-commit roots + import the global root (or wait one poll cycle)
$CLI check-status <flowId>                            # → allCommitted: true

$CLI finalize <flowId> <legId-A> $PK http://127.0.0.1:3150       # authorize (+ execute) on chain-b
```

`finalize` first sends `authorize`, which **succeeds**: the remote (chain-a-origin) leg is
proven present via an IMT inclusion proof against chain-b's imported global root, and the
local (chain-b-origin) leg via local state. Confirm on chain-b:

```bash
cast call 0x…10014 'specState(bytes32,bytes32)(uint8)' <flowId> <legId-A> --rpc-url http://127.0.0.1:3150  # → 2 (Executable)
cast call 0x…10014 'specState(bytes32,bytes32)(uint8)' <flowId> <legId-B> --rpc-url http://127.0.0.1:3150  # → 2 (Executable)
```

(`SpecState`: `0 Unset · 1 Committed · 2 Executable · 3 Executed · 4 Revertable · 5 Reverted`.)

The subsequent `execute()` reverts with `Unauthorized(0x…10014)` — expected (see
_What this demo proves_ above).

---

## Helper scripts (in `l1-contracts/test/anvil-interop/`)

| Script                   | Purpose                                                                                                                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `fund-l2.ts`             | L1→L2 ETH deposit that waits for the live server's `l1_watcher` to credit the recipient (no manual priority relay).                                                                                    |
| `atomic-root-relayer.ts` | The parallel root relayer: per-chain IMT root → L1 `GlobalInteropIMT`, global root + history → each chain's importer. `--poll <s>` runs it as a daemon.                                                |
| `atomic-flow-cli.ts`     | Flow lifecycle CLI: `register-flow-id` (`--legs-file` / `--default` / interactive), `list-flows`, `flow-info`, `commit-send`, `check-status`, `finalize`. State persisted to `atomic-flow-state.json`. |
