# protocol-ops

Rust CLI that runs Foundry scripts and optionally generates calldata for ecosystem, chain, CTM and upgrade flows.

## Build

```bash
cd protocol-ops
cargo build --release
```

## Use

```bash
./target/release/protocol_ops --help
```

### Example: register a new chain

```bash
./target/release/protocol_ops chain init \
  --ctm-proxy 0x0000000000000000000000000000000000000001 \
  --l1-da-validator 0x0000000000000000000000000000000000000002 \
  --era-validator-operator 0x0000000000000000000000000000000000000003 \
  --commit-operator 0x0000000000000000000000000000000000000004 \
  --prove-operator 0x0000000000000000000000000000000000000005 \
  --execute-operator 0x0000000000000000000000000000000000000006 \
  --chain-id 271 \
  --private-key 0x… \
  --l1-rpc-url http://localhost:8545
```

See `chain init --help` for owners, bridgehub admin keys, and forge passthrough flags.

### Common flags (most init / upgrade commands)

Most subcommands flatten **`SharedRunArgs`** from `common/args.rs`:

| Flag                             | Role                                                                |
| -------------------------------- | ------------------------------------------------------------------- |
| **`--sender`**                   | Optional sender address (with `--private-key`).                     |
| **`--private-key`** / **`--pk`** | Sender private key.                                                 |
| **`--l1-rpc-url`**               | L1 RPC (default `http://localhost:8545`).                           |
| **`--simulate`**                 | Run against a temporary Anvil fork of that RPC.                     |
| **`--out`**                      | Write the JSON envelope below to this path.                         |
| _(forge passthrough)_            | Forwarded via **`ForgeScriptArgs`** (see `--help` on each command). |

Extra signers (e.g. **`--owner`**, **`--owner-pk`**, bridgehub keys) stay on the specific command; they are not part of `SharedRunArgs`.

## Simulate mode

Pass **`--simulate`** (where supported) to run against a temporary **Anvil fork** of **`--l1-rpc-url`**. The real L1 is not modified; the fork stops when the CLI exits.

## Output

Commands that support **`--out`** write a **`CommandEnvelope`** snapshot after a successful run:

| Field              | Meaning                                                                                                                      |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| **`command`**      | CLI path id (e.g. `chain.init`, `ecosystem.upgrade`).                                                                        |
| **`version`**      | Envelope format version (currently `1`).                                                                                     |
| **`runs`**         | One entry per Forge script: `script` (path) and `run` (broadcast JSON for that script).                                      |
| **`transactions`** | Flat array in execution order: `{ "to", "data", "value" }` for replay (normalized like `cast send`). Built from every `run`. |
| **`input`**        | Serialized command input (may be `{}` if the command passes an empty object).                                                |
| **`output`**       | Command-specific result object (may be `{}`).                                                                                |

**Exception:** `chain set-upgrade-timestamp --simulate --out` writes a minimal JSON (`command`, **`transactions`**) built from `cast calldata` — no **`runs`** array.

## Requirements

You need a working Foundry toolchain (`forge`, `cast`, etc.) and repo contract artifacts as expected by the scripts this tool wraps. From the repo root, `l1-contracts` must be built (`forge build`).

### Running the Protocol Upgrade Verification Tool (PUVT)

The PUVT requires we have already run the upgrade scripts that deploy all new protocol contracts. We can run the PUVT in local (development) mode or against a live chain.

#### PUVT in Local Mode

Start an anvil fork of the L1:

```bash
anvil --fork-url <l1-rpc-url>
```

Open a new terminal and run the protocol-ops upgrade tool. `upgrade-prepare` always runs the
Foundry script against its own temporary fork and writes replayable bundles to `--out`; it does
not leave its temporary fork running. For local PUVT testing, use an Anvil default account as the
deployer so the emitted bundles can be replayed with the matching private key:

```bash
export SKIP_PUH=1
export ANVIL_RPC=http://127.0.0.1:8545
export ANVIL_DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export ANVIL_DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

rm -rf /tmp/v31-stage
mkdir -p /tmp/v31-stage/prepare

./target/release/protocol_ops ecosystem upgrade-prepare-all \
  --l1-rpc-url "$ANVIL_RPC" \
  --env stage \
  --deployer-address "$ANVIL_DEPLOYER" \
  --out /tmp/v31-stage/prepare \
  --create2-factory-salt 0x0000000000000000000000000000000000000000000000000000000000000000
```

Replay the generated deployment bundles into the persistent Anvil fork:

```bash
rm -f /tmp/v31-stage/executed.json
for bundle in /tmp/v31-stage/prepare/*.safe.json; do
  ./target/release/protocol_ops dev execute-safe \
    --l1-rpc-url "$ANVIL_RPC" \
    --safe-file "$bundle" \
    --private-key "$ANVIL_DEPLOYER_PK" \
    --out /tmp/v31-stage/executed.json
done
```

Then run the verifier against the same Anvil fork and the merged TOML
produced by `upgrade-prepare-all`:

```bash
./target/release/protocol_ops ecosystem verify-upgrade \
  --ecosystem-toml /tmp/v31-stage/prepare/ecosystem.toml \
  --l1-rpc-url "$ANVIL_RPC" \
  --era-chain-id 270 \
  --executed-bundles /tmp/v31-stage/executed.json \
  --create2-salt 0x88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5 \
  --zk-token-asset-id 0xd7912bfd25000ee1b3355167866f960a61787b79cd2c7e791036fe6e85a73823
```

(The salt above is `--env stage`'s `permanent_contracts.create2_factory_salt`; substitute your env's value.)

`--zk-token-asset-id` is recommended for production verification runs. When omitted, `zkTokenAssetId`
is only checked to be non-zero and a warning is emitted.

The `--create2-factory` flag defaults to the standard Foundry CREATE2
factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) used by the v31
prepare scripts; override only if your prepare run targeted a different
factory.

### Regenerating the committed v31 stage calldata

The repo tracks one canonical artifact for the v31 stage upgrade:

```
l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml
```

It carries the merged `[governance_calls]` (PUH stage 0/1/2 hex), `[core]`,
`[ctms.<flavor>]` (Era + ZKsyncOS), and `[new_gateway]` sections. Reviewers
diff it; downstream tools (PUVT, the simulator converter) read it.

The full prepare → fork-broadcast → PUVT cycle is wrapped in
`l1-contracts/test/anvil-interop/regen-and-verify-stage.sh`. Use it whenever
contracts or upgrade scripts change. Steps:

```bash
# 0. Rebuild artifacts that the prepare phase reads.
cd contracts
yarn sc build:foundry                       # zkout/ — genesis hashes
cd l1-contracts && forge build              # out/  — l1 artifacts
cd ../protocol-ops && cargo build           # target/debug/protocol_ops

# 1. Regen against a Sepolia fork. Writes prepare/* + executed.json under
#    upgrade-envs/v0.31.0-interopB/output/stage/regen/ and runs PUVT.
cd ../l1-contracts
DEPLOYER_PK_FILE=~/.test_pk \
L1_FORK_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
bash test/anvil-interop/regen-and-verify-stage.sh

# 2. Promote the regen output to the tracked path.
cp upgrade-envs/v0.31.0-interopB/output/stage/regen/prepare/ecosystem.toml \
   upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml

# 3. Regenerate every derived artifact CI checks, then commit.
cd ..
yarn lint:sol --fix --noPrompt && yarn lint:ts --fix && yarn prettier:fix
cd l1-contracts && yarn selectors --fix
ts-node scripts/copy-to-zkstack-out.ts
cd .. && yarn calculate-hashes:fix
git add l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml \
        l1-contracts/selectors l1-contracts/zkstack-out AllContractsHashes.json
git commit -m "Regenerate v31 stage calldata"

# 4. Broadcast CREATE2 deploys to real Sepolia so the simulator's local fork
#    finds bytecode at every CREATE2-derived address governance touches.
#    The script is idempotent: it pre-filters against on-chain `eth_getCode`
#    and only sends contracts not already deployed.
DEPLOYER_PK_FILE=~/.test_pk \
L1_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/<key>" \
bash test/anvil-interop/broadcast-deployer-bundle-to-sepolia.sh

# 5. Emit the matching tx-simulator scenario (Safe-bundle JSON shape).
#    --include-manifest pulls in deployer + SC + CTM-admin Safe bundles so
#    the simulator's local fork has everything it needs in execution order;
#    `protocol-ops` filters out non-broadcastable selectors (ZK approves,
#    GW priority requests, already-executed scheduleTransparent).
cd protocol-ops
./target/debug/protocol_ops ecosystem governance-toml-to-simulator \
  --env stage \
  --governance-toml ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml \
  --include-manifest ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/regen/prepare/manifest.json \
  --out <transaction-simulator>/transactions/$(date +%F)-v31-interopB-stage.json
```

The script can be iterated quickly with two env flags:

| Flag               | Effect                                                              |
| ------------------ | ------------------------------------------------------------------- |
| `SKIP_PREPARE=1`   | Reuse the existing `regen/prepare/` (skip step 1's forge scripts)   |
| `SKIP_BROADCAST=1` | Reuse `regen/executed.json` (skip funding + bundle replay)          |
| `KEEP_ANVIL=1`     | Leave the fork anvil running on port 29545 for ad-hoc `cast` probes |

CI checks that fail if any step in (3) is missed: `solhint`, `eslint`,
`prettier:check`, the `selectors` file, `AllContractsHashes.json`, the
`zkstack-out/*.json` set, and `codespell` on prose.
