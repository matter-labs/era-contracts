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
  --commit-operator 0x0000000000000000000000000000000000000003 \
  --prove-operator 0x0000000000000000000000000000000000000004 \
  --chain-id 271 \
  --private-key 0x… \
  --l1-rpc-url http://localhost:8545
```

See `chain init --help` for owners, bridgehub admin keys, and forge passthrough flags.

### Common flags (most init / upgrade commands)

Most subcommands flatten **`SharedRunArgs`** from `common/args.rs`:

| Flag | Role |
|------|------|
| **`--sender`** | Optional sender address (with `--private-key`). |
| **`--private-key`** / **`--pk`** | Sender private key. |
| **`--l1-rpc-url`** | L1 RPC (default `http://localhost:8545`). |
| **`--simulate`** | Run against a temporary Anvil fork of that RPC. |
| **`--out`** | Write the JSON envelope below to this path. |
| *(forge passthrough)* | Forwarded via **`ForgeScriptArgs`** (see `--help` on each command). |

Extra signers (e.g. **`--owner`**, **`--owner-pk`**, bridgehub keys) stay on the specific command; they are not part of `SharedRunArgs`.

## Simulate mode

Pass **`--simulate`** (where supported) to run against a temporary **Anvil fork** of **`--l1-rpc-url`**. The real L1 is not modified; the fork stops when the CLI exits.

## Output

Commands that support **`--out`** write a **`CommandEnvelope`** snapshot after a successful run:

| Field | Meaning |
|--------|--------|
| **`command`** | CLI path id (e.g. `chain.init`, `ecosystem.upgrade`). |
| **`version`** | Envelope format version (currently `1`). |
| **`runs`** | One entry per Forge script: `script` (path) and `run` (broadcast JSON for that script). |
| **`transactions`** | Flat array in execution order: `{ "to", "data", "value" }` for replay (normalized like `cast send`). Built from every `run`. |
| **`input`** | Serialized command input (may be `{}` if the command passes an empty object). |
| **`output`** | Command-specific result object (may be `{}`). |

**Replay on a real RPC:** `chain execute-simulated-transactions` reads a previously written envelope, extracts **`transactions`**, and runs `l1-contracts/deploy-scripts/ExecuteProtocolOpsOut.s.sol`. Example:

```bash
./target/release/protocol_ops chain execute-simulated-transactions \
  --out /path/from/protocol-ops.json \
  --private-key … \
  --l1-rpc-url …
```

Here **`--out`** is the **input** path to that JSON file (not an envelope field name).

**Exception:** `chain set-upgrade-timestamp --simulate --out` writes a minimal JSON (`command`, **`transactions`**) built from `cast calldata` — no **`runs`** array.

## Requirements

You need a working Foundry toolchain (`forge`, `cast`, etc.) and repo contract artifacts as expected by the scripts this tool wraps. From the repo root, `l1-contracts` must be built (`forge build`).
