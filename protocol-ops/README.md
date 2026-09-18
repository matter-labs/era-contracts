# protocol-ops

Rust CLI that runs Foundry scripts and optionally generates calldata for ecosystem, chain, CTM and upgrade flows.

## Build

```bash
cd protocol-ops
cargo build --release
```

## Use

Run all commands below from the `protocol-ops` directory.

```bash
cargo run --release --bin protocol_ops -- --help
```

### Example: register a new chain

```bash
cargo run --release --bin protocol_ops -- chain init \
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

| Flag                  | Role                                                                |
| --------------------- | ------------------------------------------------------------------- |
| **`--l1-rpc-url`**    | L1 RPC (default `http://localhost:8545`).                           |
| **`--out`**           | Output directory for Safe bundles + `manifest.json`.                |
| _(forge passthrough)_ | Forwarded via **`ForgeScriptArgs`** (see `--help` on each command). |

> **`--deployer-address` / `--private-key`** are **not** part of `SharedRunArgs`.
> Bootstrap and apply commands declare their own deployer key flags because they need
> an EOA to simulate forge scripts against the Anvil fork. Extra signers (e.g.
> **`--owner`**, bridgehub keys) stay on specific commands.

## Execution model

Every command that generates Safe bundles runs **exclusively against a temporary Anvil fork**
of `--l1-rpc-url`. The real L1 is **never modified** by the CLI. The fork exists only for
the duration of the command and stops when it exits.

To apply the generated Safe bundles to a real chain, use `dev execute-manifest` (or any
Safe-bundle-aware executor) with the keys from `wallets.yaml`.

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

## Requirements

You need a working Foundry toolchain (`forge`, `cast`, etc.) and repo contract artifacts as expected by the scripts this tool wraps. From the repo root, `l1-contracts` must be built (`forge build`).

### Running the Protocol Upgrade Verification Tool (PUVT)

The PUVT requires we have already run the upgrade scripts that deploy all new protocol contracts. For v31 stage, regenerate the calldata and replay the prepare bundles on a pinned Sepolia fork, then run PUVT against the same fork.

Start a read-only Sepolia fork. Keep the RPC URL out of committed files:

```bash
export L1_RPC_URL='<sepolia-rpc-url>'

anvil \
  --fork-url "$L1_RPC_URL" \
  --port 48546 \
  --auto-impersonate \
  --disable-block-gas-limit \
  --base-fee 0
```

In a second shell, generate the stage artifact:

```bash
cd protocol-ops

cargo run --release --bin protocol_ops -- ecosystem upgrade-prepare-all \
  --env stage \
  --bridgehub 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE \
  --l1-rpc-url http://127.0.0.1:48546 \
  --deployer-address 0x343Ee72DdD8CCD80cd43D6Adbc6c463a2DE433a7 \
  --out ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/prepare \
  --additional-args=--memory-limit=536870912 \
  --additional-args=--offline \
  --additional-args=--skip-simulation
```

This writes the canonical merged calldata to `l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml`. The `prepare/` subdirectory contains `manifest.json` and replayable `*.safe.json` bundles.
We can send these to the local L1 fork via:

```bash
cargo run --release --bin protocol_ops -- ecosystem upgrade-broadcast \
  --manifest ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/prepare/manifest.json \
  --l1-rpc-url http://127.0.0.1:48546 \
  --unlocked \
  --out ../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/executed-bundles.json
```

The deployment tx hashes are appended to the committed `transactions.txt` next to `ecosystem.toml`.
PUVT reads that file, fetches each tx via `--l1-rpc-url`, and reconstructs the deployment provenance.

```bash
export L1_RPC_URL=http://127.0.0.1:48546
export GW_RPC_URL=<gateway-rpc-url>

cargo run --release --bin protocol_ops -- ecosystem verify-upgrade \
  --env stage \
  --ecosystem-toml "../l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml" \
  --l1-rpc-url "$L1_RPC_URL" \
  --gw-rpc-url "$GW_RPC_URL" \
  --zk-governance-commit 41ad762d7478c80e1e8c3a2c8cabbdfca9f7ffce
```

Other knobs (all read from `permanent-values/<env>.toml` and the v31 input
TOML when `--env` is set — pass an explicit flag to override):

| Flag                            | Default source                                                               | When to override                                                                                                                                                                                                          |
| ------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--transactions-log <path>`     | `<l1-contracts>/upgrade-envs/v0.31.0-interopB/output/<env>/transactions.txt` | Verifying a custom rollout output dir.                                                                                                                                                                                    |
| `--contracts-commit <hash>`     | local checkout                                                               | Verifying against contract metadata from a different commit. When omitted, local `AllContractsHashes.json` and `SystemConfig.json` are authoritative, so first verify the checkout matches the reviewed contracts commit. |
| `--zk-governance-commit <hash>` | required                                                                     | PUVT fetches zk-governance `AllContractsHashes.json` at this commit and uses it to provenance-check the deployed contracts recorded in `[zk_governance]`.                                                                 |
