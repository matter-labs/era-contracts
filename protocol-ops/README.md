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

## Verifying a registry-driven upgrade before it is signed

`ecosystem verify-bootstrap` (alias `verify-package`) is the verifier for current packages. It
reads the merged `ecosystem.toml`, decides from the package itself whether it drives a recurring
upgrade or the one-time bootstrap edge, and refuses a package that is neither. It is read-only and
needs nothing but that file and an L1 RPC.

```bash
cargo run --release --bin protocol_ops -- ecosystem verify-bootstrap \
  --ecosystem-toml <path-to>/ecosystem.toml \
  --l1-rpc-url <l1-rpc-url> \
  --expected-governance-owner 0x... \
  --create2-salt 0x...
```

It answers two questions and keeps them apart.

**What does this upgrade do?** is answered by reviewing the objects the package names — the
operation, the transition it may carry, the release pair, the core registry, and the lifecycle
objects it runs through (the coordinator, both domain executors, the timer; for the bootstrap edge
also the migration and the sequence its calls are derived from). Each is held against its own
construction: the reviewed creation code, run on that object's reviewed constructor arguments,
must land at the object's address. For a write-once object those arguments are the manifest it
serves; for a lifecycle object they are the reviewed governance owner and the bindings the package
records — never the object's own getters, since a genuine executor built for an attacker's owner
answers them exactly like the reviewed one. That is what establishes the audited CONSTRUCTOR
produced it, which a runtime codehash cannot (and the lifecycle objects set immutables, so no
codehash identifies them at all) — so it needs the reviewed commit built locally
(`cd l1-contracts && forge build`) for the creation code BYTES, and the reviewed CREATE2 salts:
the core prepare's `[contracts] create2_factory_salt` and the CTM prepare's
`[create2_factory_salts]` entry, both passed as `--create2-salt` (a package records neither).
The immutable-free objects are additionally identified against `AllContractsHashes.json`.

**Does the signed transaction invoke it?** is answered, for a recurring upgrade, by re-encoding
`EcosystemUpgradeExecutor.stage0/1/2(operation)` on the reviewed coordinator and comparing byte
for byte. The operation's internal calls are deliberately not re-derived — the executors derive
them on chain from the same pinned object. Any call that is neither a lifecycle call nor a
declared external action fails the run. For the bootstrap edge each stage must carry the run the
construction-verified sequence derives, in order, and every other call must be a declared external
action to a target outside the edge's authorities — an extra call to the CTM, a `ProxyAdmin`, an
executor, the timer or an object is an error whether declared or not.

Around those it checks what the objects cannot answer for themselves: authority bound where the
review says (governance, coordinator, both domain executors, the CTM and both ProxyAdmins), the
live state the upgrade departs from, and readiness — the L2 factory dependencies published on the
CTM's supplier, the timer startable, no lifecycle already in flight. Readiness is reported apart
from anything about value.

Anything a reviewer could not establish is an ERROR, never a warning: warnings do not fail a run,
so an unverifiable input reported as one reads, afterwards, exactly like a check that passed.

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
