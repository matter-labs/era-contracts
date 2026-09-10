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
  --bridgehub 0x0000000000000000000000000000000000000001 \
  --l1-da-validator 0x0000000000000000000000000000000000000002 \
  --deployer-address 0x0000000000000000000000000000000000000003 \
  --commit-operator 0x0000000000000000000000000000000000000004 \
  --prove-operator 0x0000000000000000000000000000000000000005 \
  --execute-operator 0x0000000000000000000000000000000000000006 \
  --chain-id 271 \
  --l1-rpc-url http://localhost:8545
```

See `chain init --help` for owners, advanced input, and forge passthrough flags.

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
> **`--owner`**) stay on specific commands.

## Execution model

Every command that generates Safe bundles runs **exclusively against a temporary Anvil fork**
of `--l1-rpc-url`. The real L1 is **never modified** by the CLI. The fork exists only for
the duration of the command and stops when it exits.

To apply the generated Safe bundles to a real chain, use `dev execute-manifest` (or any
Safe-bundle-aware executor) with the keys from `wallets.yaml`.

## Running the Protocol Upgrade Verification Tool (PUVT)

`ecosystem verify-upgrade` re-derives and cross-checks the calldata produced by
`ecosystem upgrade-prepare-all` for the **v31 → v32 ZKsync OS upgrade**. It is
**read-only**: it never runs forge or spins up an Anvil fork. It reads the merged
`ecosystem.toml`, replays the append-only `transactions.txt` deployment log against L1,
and matches every CREATE2 deployment against `AllContractsHashes.json`. The tool is
OS-only — an `ecosystem.toml` carrying a `[ctms.era]` section is rejected at parse time.

```bash
cargo run --release --bin protocol_ops -- ecosystem verify-upgrade \
  --env stage \
  --ecosystem-toml <path-to>/ecosystem.toml \
  --gw-rpc-url <gateway-rpc-url> \
  --zk-governance-commit <commit>
```

| Flag                         | Role                                                                                           |
| ---------------------------- | ---------------------------------------------------------------------------------------------- |
| **`--env`**                  | `stage` / `testnet` / `mainnet`; selects the permanent-values + v31 input TOMLs.               |
| **`--ecosystem-toml`**       | Merged artifact from `upgrade-prepare-all`.                                                    |
| **`--zk-governance-commit`** | zk-governance commit for PUH / Guardians / SecurityCouncil / EUB bytecode metadata (required). |
| **`--contracts-commit`**     | Optional era-contracts commit; when omitted, the local checkout is the authority.              |
| **`--transactions-log`**     | Deployment tx-hash log; defaults to the env's `output/<env>/transactions.txt`.                 |
| **`--l1-rpc-url`**           | L1 RPC (default `http://localhost:8545`).                                                      |
| **`--gw-rpc-url`**           | Gateway RPC (alias `--gw-rpc`) for read-only gateway-side checks.                              |
| **`--display-upgrade-data`** | Print each stage's ABI-encoded `UpgradeProposal` and skip the rest of the verifier.            |

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
