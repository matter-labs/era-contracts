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
export ANVIL_RPC=http://127.0.0.1:8545
export ANVIL_DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export ANVIL_DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

rm -rf /tmp/v31-stage
mkdir -p /tmp/v31-stage

./target/release/protocol_ops ecosystem upgrade-prepare \
  --l1-rpc-url "$ANVIL_RPC" \
  --ecosystem ../environments/stage/stage.yaml \
  --deployer-address "$ANVIL_DEPLOYER" \
  --upgrade-input-path /upgrade-envs/v0.31.0-interopB/stage.toml \
  --create2-factory-salt 0x83de3677ffea74c9815331db7f4c737a32c161db4cae7d47504a336c4c5bcfb7 \
  --bytecodes-supplier-address 0x662B8fE285BB3aab483e75Ec46136e01aaa154f9 \
  --rollup-da-manager-address 0xeb7c0daaddfb52afa05400b489e7497b271d6122 \
  --is-zk-sync-os false \
  --governance-toml-out /tmp/v31-stage/governance.toml \
  --out /tmp/v31-stage/safe
```

Replay the generated deployment bundles into the persistent Anvil fork:

```bash
for bundle in /tmp/v31-stage/safe/*.safe.json; do
  ./target/release/protocol_ops dev execute-safe \
    --l1-rpc-url "$ANVIL_RPC" \
    --safe-file "$bundle" \
    --private-key "$ANVIL_DEPLOYER_PK"
done
```

Then run the verifier against the same Anvil fork and the TOML produced by `upgrade-prepare`:

```bash
./target/release/protocol_ops ecosystem verify-upgrade \
  --ecosystem-toml ../l1-contracts/script-out/v31-upgrade-ecosystem.toml \
  --l1-rpc-url "$ANVIL_RPC" \
  --era-chain-id <era-chain-id>
```
