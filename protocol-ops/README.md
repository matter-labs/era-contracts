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

## Preparing protocol v34

`ecosystem upgrade-prepare-all` defaults to `DefaultCoreUpgrade` and `CTMUpgrade_v34` (the default CTM
upgrade with the v34 per-chain upgrade, `V34UpgradeZKsyncOS`), using `upgrade-envs/v0.34.0-chain-config/local.toml` for a local v33-to-v34 upgrade.
For a named environment, provide its v34 TOML through `--upgrade-input-path` or place it under the v34
input directory; missing inputs fail before deployment. Environment addresses and salts must match the
target environment.

`--ctm-script-path`, `--core-script-path`, and `--upgrade-input-path` are visible in `--help`.
Historical preparations must select the matching scripts and input explicitly. The anvil upgrade test
(`l1-contracts/test/anvil-interop/run-upgrade-test.ts`) uses the defaults with no overrides, so it always
covers the current release's upgrade. See
[the activation requirements](../protocol-docs/chain-config.md#activation).

## Environment inputs

`--env <name>` reads `upgrade-envs/permanent-values/<name>.toml` and the release input
`<release dir>/<name>.toml`. The release dir is the current release's (`current_upgrade_env_dir!` in
`src/common/forge/scripts/mod.rs`) unless `--upgrade-env-dir` selects another (on the commands built on the
shared `--env` topology args and on `verify-upgrade`; `ecosystem init` / `ctm init` always use the current
release), or `upgrade-prepare-all`'s
`--upgrade-input-path` points into another release's dir. The owner, `era_chain_id` and CREATE2 salts come
from that release input, and a command that needs one of them fails when the release has no input for the
env: it never falls back to the deployer, local's values or random salts. `yarn new-release` creates the next
release's inputs from the current ones with fresh salts.

## Execution model

Every command that generates Safe bundles runs **exclusively against a temporary Anvil fork**
of `--l1-rpc-url`. The real L1 is **never modified** by the CLI. The fork exists only for
the duration of the command and stops when it exits.

To apply the generated Safe bundles to a real chain, use `dev execute-manifest` (or any
Safe-bundle-aware executor) with the keys from `wallets.yaml`.

## Running the Protocol Upgrade Verification Tool (PUVT)

> **Not ported to v34 yet.** On this line `verify-upgrade` still runs the v31 verifier
> (`upgrade_verification/versions/v31`), which is pinned to the 0.31.0 → 0.32.0 transition and rejects a
> v34 bundle (0.33.x → 0.34.0) in stage 1. The working v33 verifier lives on
> `release/v0.33.0-atomic-interop` (`versions/v33`); porting it to v34 must also move the cut-initializer
> check to `v34_upgrade_addr`.

`ecosystem verify-upgrade` re-derives and cross-checks the calldata produced by
`ecosystem upgrade-prepare-all` for a **ZKsync OS upgrade**. It is
**read-only**: it never runs forge or spins up an Anvil fork. It reads the merged
`ecosystem.toml`, replays the append-only `transactions.txt` deployment log against L1,
and matches every CREATE2 deployment against `AllContractsHashes.json`. The tool is
OS-only — an `ecosystem.toml` carrying a `[ctms.era]` section is rejected at parse time.

```bash
cargo run --release --bin protocol_ops -- ecosystem verify-upgrade \
  --env stage \
  --ecosystem-toml <path-to>/ecosystem.toml \
  --zk-governance-commit <commit>
```

| Flag                         | Role                                                                                           |
| ---------------------------- | ---------------------------------------------------------------------------------------------- |
| **`--env`**                  | `stage` / `testnet` / `mainnet`; selects the permanent-values + current-release input TOMLs.   |
| **`--ecosystem-toml`**       | Merged artifact from `upgrade-prepare-all`.                                                    |
| **`--zk-governance-commit`** | zk-governance commit for PUH / Guardians / SecurityCouncil / EUB bytecode metadata (required). |
| **`--contracts-commit`**     | Optional era-contracts commit; when omitted, the local checkout is the authority.              |
| **`--transactions-log`**     | Deployment tx-hash log; defaults to the env's `output/<env>/transactions.txt`.                 |
| **`--upgrade-env-dir`**      | Release dir for the env input and the default log; defaults to the current release.            |
| **`--l1-rpc-url`**           | L1 RPC (default `http://localhost:8545`).                                                      |
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
