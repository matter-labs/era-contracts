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

## Preparing an upgrade

`ecosystem upgrade-prepare-all` defaults to the current release's scripts, `CoreUpgrade_v35` and `CTMUpgrade_v35`
under `l1-contracts/deploy-scripts/upgrade/v35/` (the one-time bootstrap edge onto registry-driven upgrades;
`CTMUpgrade_v35` also deploys the `L1InteropFeeManager` proxy, see
[the switch](../protocol-docs/interop-fee.md#the-switch)), using `upgrade-envs/v0.35.0-upgrade-system/local.toml` for a
local upgrade. The recurring registry-driven edge, `CoreUpgrade_v36` and `CTMUpgrade_v36` under
`l1-contracts/deploy-scripts/upgrade/v36/`, is selected with `--core-script-path` / `--ctm-script-path`.
With `--env <name>` the input is `<release dir>/<name>.toml` (see [Environment inputs](#environment-inputs));
missing inputs fail before deployment.

The merged package `<env-out>/ecosystem.toml` carries ONE governance bundle, `[governance_calls] calls`, in this
order: the merge's own extras (the PUH/Guardians wiring when the release redeploys the governance set, then any CTM
`acceptOwnership()` normalization), the core prepare's declared calls, the derived
`EcosystemUpgradeExecutor.execute(operation)` (recurring upgrades only), then the CTM prepare's declared calls.
Every call but `execute` is declared in `external_actions`. A recurring upgrade's bundle is therefore one call
when nothing else is declared; the bootstrap edge's is the list `RegistryBootstrapSequence.actions()` derives,
ending in the edge's completion check `validateApplied()`, so an edge that does not complete reverts the whole
bundle. `ecosystem upgrade-governance` replays that bundle on a fork as the governance owner.

A fresh ecosystem (`ecosystem init`, or `hub init` + `ctm init`) is born into the registry model: the
deployer creates the core executor, the coordinator and the CTM executor, hands them the ProxyAdmins, the CTM
and the ServerNotifier, and nominates the ecosystem governance, which `hub init` / `ctm init` accept. Its first
upgrade is therefore a recurring one, never the bootstrap edge. Owner operations on its CTM go through
`CTMUpgradeExecutor.forward`.

`--ctm-script-path`, `--core-script-path`, and `--upgrade-input-path` are visible in `--help`.
Historical preparations must select the matching scripts and input explicitly. The anvil upgrade test
`l1-contracts/test/anvil-interop/run-upgrade-test.ts` passes its test subclasses of these scripts explicitly, for
the bootstrap edge and the recurring hops after it (`run-recurring-upgrade-test.ts` drives a registry-driven hop on
a fresh ecosystem's own executors without protocol-ops). See
[the activation requirements](../protocol-docs/chain-config.md#activation).

### Replacing a committed transition

A transition already committed for a departed version is repaired with
`ChainTypeManager.replaceUpgradeTransition` (see
[Replacing a committed transition](../protocol-docs/ecosystem-upgrade-coordination.md#replacing-a-committed-transition)).
Prepare it as the CTM prepare of an ordinary `upgrade-prepare-all`, naming the replaced transition in the upgrade
input:

```toml
[transition_replacement]
replaced_transition = "0x..."          # the transition committed for the departure, as the CTM names it now
protocol_version_deadline = 1900000000 # optional: also move the departing version's deadline
```

```bash
cargo run --release --bin protocol_ops -- ecosystem upgrade-prepare-all --env <env> \
  --deployer-address 0x... \
  --ctm-script-path deploy-scripts/upgrade/default-upgrade/DefaultTransitionReplacement.s.sol
```

The prepare deploys only the replacement `CTMTransition` (under the CTM salt), landing on an existing release,
and emits one governance call, `CTMUpgradeExecutor.forward([replaceUpgradeTransition(expected,
replacement)])`, optionally followed in the same `forward` by `setProtocolVersionDeadline`. The merged package
has no `[operation]`; `upgrade-governance` replays it like any other. Verify it with `verify-package` before it
is signed (see below).

## Environment inputs

`--env <name>` reads `upgrade-envs/permanent-values/<name>.toml` and the release input
`<release dir>/<name>.toml`. A release input holds only what is read from it: `owner_address`, `era_chain_id`
and the CREATE2 / legacy-Gov salts (`[contracts] create2_factory_salt`, `legacy_gov_salt`,
`[create2_factory_salts]`, rotated every release because CREATE2 returns the previously deployed contract on a
reused salt) and `redeploy_zk_governance` (whether this release replaces the PUH governance set). The old
protocol version comes from each CTM and the target from `configs/genesis/zksync-os/latest.json`. The release dir is the current release's (`current_upgrade_env_dir!` in
`src/common/forge/scripts/mod.rs`) unless `--upgrade-env-dir` selects another (on the commands built on the
shared `--env` topology args; `ecosystem init` / `ctm init` always use the current release). It is the only release selector: `upgrade-prepare-all` rejects an `--upgrade-input-path` outside the
selected release dir rather than mixing one release's input with another's salts. The owner, `era_chain_id`
and CREATE2 salts come
from that release input, and a command that needs one of them fails when the release has no input for the
env: it never falls back to the deployer, local's values or random salts. `yarn new-release` creates the next
release's inputs from the current ones with fresh salts.

## Execution model

Every command that generates Safe bundles runs **exclusively against a temporary Anvil fork**
of `--l1-rpc-url`. The real L1 is **never modified** by the CLI. The fork exists only for
the duration of the command and stops when it exits.

To apply the generated Safe bundles to a real chain, use `ecosystem upgrade-broadcast --manifest
<out>/manifest.json` (one `--key` per signer in the manifest), `dev execute-safe` per bundle, or
any Safe-bundle-aware executor.

## Verifying a registry-driven upgrade before it is signed

`ecosystem verify-bootstrap` (alias `verify-package`) is the verifier for current packages. It
reads the merged `ecosystem.toml`, decides from the package itself whether it drives a recurring
upgrade, the one-time bootstrap edge or a transition replacement, and refuses a package that is none
of them. It is read-only and needs nothing but that file, an L1 RPC and the reviewer's inputs.

```bash
cargo run --release --bin protocol_ops -- ecosystem verify-bootstrap \
  --ecosystem-toml <path-to>/ecosystem.toml \
  --l1-rpc-url <l1-rpc-url> \
  --expected-governance-owner 0x... \
  --create2-salt 0x... \
  --env <env> \
  --executor-record l1-contracts/script-out/output-deploy-l1.toml \
  --executor-record l1-contracts/script-out/output-deploy-ctm.toml
```

It answers two questions and keeps them apart.

**What does this upgrade do?** is answered by reviewing the objects the package names — the
operation, the transition it may carry, the release pair, the core registry, and the lifecycle
objects it runs through (the coordinator and both domain executors; for the bootstrap edge also the
migration and the sequence its calls are derived from). Each is held against its own
construction: the reviewed creation code, run on that object's reviewed constructor arguments,
must land at the object's address. For a write-once object those arguments are the manifest it
serves; for an executor they are the ones its record states (below), and for the bootstrap
sequence the migration and core transition the package names — never the object's own getters,
since a genuine executor built for an attacker's owner answers them exactly like the reviewed one.
That is what establishes the audited CONSTRUCTOR produced it, which a runtime codehash cannot (and
the lifecycle objects set immutables, so no codehash identifies them at all) — so it needs the
reviewed commit built locally
(`cd l1-contracts && forge build`) for the creation code BYTES, and the reviewed CREATE2 salts:
the core prepare's `[contracts] create2_factory_salt` and the CTM prepare's
`[create2_factory_salts]` entry, both passed as `--create2-salt` (a package records neither).
An executor is re-derived from its EXECUTOR RECORD, which is mandatory: the `[upgrade_executors]`
table the run that deployed it wrote (the `ecosystem init` / `ctm init` forge outputs
`script-out/output-deploy-l1.toml` / `output-deploy-ctm.toml`, or a bootstrap package, which carries
its own), passed with the repeatable `--executor-record`. The record's salt and ORIGINAL constructor
arguments re-derive the address; its immutable bindings are still held against the package's values,
and its initial owner is only reported — a fresh ecosystem constructs its executors for the deployer
and nominates governance. An executor without a record is unverified, which is an error. The live
owner, pending owner and coordinator are checked separately. The immutable-free objects are
additionally identified against `AllContractsHashes.json`. Every release the package installs is
held against the reviewed genesis: `genesisBatchHash` against the `genesis_root` of
`configs/genesis/zksync-os/latest.json`, `genesisIndexRepeatedStorageChanges` against zero, and
`fixedForceDeploymentsData` against the package's `force_deployments_data` — and decoded, with every
field held against an independent expectation: `l1ChainId` against the RPC's chain id,
`l1AssetRouter`, `maxNumberOfZKChains` and the aliased chain registration sender against the CTM's
live Bridgehub, `aliasedL1Governance` against the alias of the reviewed governance, `zkTokenAssetId`
against the `zk_token_asset_id` of `upgrade-envs/permanent-values/<env>.toml` for the `--env` the
package is held against (required unless the package is a replacement), the legacy and test-only
addresses against zero, and each bytecode field against the release's own L2 bytecode table. The
arriving release's system-proxy shell is compared with the departing one's, compiler metadata
stripped: a logic change fails unless the edge ships a delegate the reviewed commit builds other
than the stock `L2DefaultUpgrade`, which is then reported for the reviewer to confirm.

A transition replacement is held against the transition it replaces rather than the CTM's current
state: the replacement's construction as for any transition, the same source release (the replaced
transition's, not the CTM's current one) and pinned deadline, `upgradeTransition[departure]` still
the expected one and not the replacement, a departure below the CTM's version, a target no earlier
than the replaced one that is the CTM's current release at its version or else the source of the
edge committed onward from it, and the replacement's L2 bytecodes published. The effective deadline
and any `setProtocolVersionDeadline` riding the `forward` are reported. The destination is an
existing release, so no genesis is judged on this path.

**Does the signed transaction invoke it?** is answered, for a recurring upgrade, by re-encoding
`EcosystemUpgradeExecutor.execute(operation)` on the reviewed coordinator and comparing byte for
byte; the bundle must carry it exactly once. The operation's internal calls are deliberately not
re-derived — the executors derive them on chain from the same pinned object. Any call that is
neither the executor call nor a declared governance external action fails the run. For the
bootstrap edge the bundle must END with the run `actions()` of the construction-verified sequence
derives, in order — whose last call is `validateApplied()` on the migration, so a failing completion
check reverts the whole bootstrap — and every call before it must be a declared external action to
a target outside the edge's authorities: an extra call to the CTM, a `ProxyAdmin`, an executor or an
object is an error whether declared or not. A replacement's bundle must carry the one `forward`,
sent to the executor that owns the CTM, and nothing else may reach the CTM or its executor.

Around those it checks what the objects cannot answer for themselves: authority bound where the
review says (governance, coordinator, both domain executors, the CTM and both ProxyAdmins), the
live state the upgrade departs from, and readiness — the L2 factory dependencies published on the
CTM's supplier. Readiness is reported apart
from anything about value. For the bootstrap edge it also lists, as warnings, every chain on the
CTM still below the departing version: those chains keep upgrading along the pre-registry edges
through the CTM's legacy `protocolVersionVerifier` getter.

Anything a reviewer could not establish is an ERROR, never a warning: warnings do not fail a run,
so an unverifiable input reported as one reads, afterwards, exactly like a check that passed.

## Output

Commands that support **`--out`** write, into that directory, one Safe Transaction Builder JSON
file per consecutive run of transactions by the same signer, plus a **`manifest.json`**:

| Field          | Meaning                                                                                                                             |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **`bundles`**  | One entry per bundle file, in execution order: `index`, `file`, `target` (the signer), `steps`, `tx_count`.                         |
| **`metadata`** | One entry per command run into this directory: `command` (CLI path id, e.g. `chain.init`), `input` and `output` (both may be `{}`). |

Without `--out` no bundles are written, unless the command derives a default from `--env`:
`upgrade-prepare-all` (which also rewrites the release's canonical `ecosystem.toml`),
`upgrade-governance` and `chain upgrade` do.

## Requirements

You need a working Foundry toolchain (`forge`, `cast`, etc.) and repo contract artifacts as expected by the scripts this tool wraps. From the repo root, `l1-contracts` must be built (`forge build`).
