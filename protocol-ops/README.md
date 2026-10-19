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
`acceptOwnership()` normalization), the core prepare's declared calls, the derived executor legs, then the CTM
prepare's declared calls. The legs are one contiguous run in canonical order, each present only when its prepare
reported the object (`[registry]` of the core and CTM prepare outputs), all with no value:

1. `CoreUpgradeExecutor.applyL1Upgrade(core_transition_addr)` on `core_upgrade_executor_addr`;
2. `CTMUpgradeExecutor.applyInfrastructureUpgrade(ctm_infrastructure_transition_addr)` on
   `ctm_upgrade_executor_addr`;
3. `CTMUpgradeExecutor.applyCTMUpgrade(ctm_transition_addr)` on `ctm_upgrade_executor_addr`.

Governance executes the whole bundle in one transaction that reverts on any failing call, so the legs apply in
that order or not at all (see
[the coordination doc](../protocol-docs/ecosystem-upgrade-coordination.md)). A core-only upgrade needs no CTM leg.
Every call but a leg is declared in `external_actions`, and each prepare must emit its declared actions in
declaration order. The merge refuses a package that would leave a reported object unapplied or that upgrades
nothing, and a leg whose executor is missing or zero. The bootstrap edge derives no leg: its bundle is the list
`RegistryBootstrapSequence.actions()` derives (the core transition included), ending in the edge's completion
check `validateApplied()`, so an edge that does not complete reverts the whole bundle. `ecosystem
upgrade-governance` replays that bundle on a fork as the governance owner, then holds the fork against everything a
registry package must leave behind, part of which the contracts check themselves: the CTM at the
target version and release with the transition committed for its departure (the release at the CTM's version),
every row's proxy at its `implNew`, the CTM, its ProxyAdmin and its ServerNotifier owned by the CTM executor with
no nomination and the notifier bound to the CTM, the ecosystem ProxyAdmin owned by the core executor, and every
executor owned by governance with no nomination (for a replacement, the CTM committing the replacement). Any unmet
expectation fails the command.

A fresh ecosystem (`ecosystem init`, or `hub init` + `ctm init`) is born into the registry model: the
deployer creates the core executor and the CTM executor, hands them the ProxyAdmins, the CTM and the
ServerNotifier, and nominates the ecosystem governance, which `hub init` / `ctm init` accept. Its first upgrade
is therefore an ordinary one, never the bootstrap edge. Owner operations on its CTM go through
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
replacement)])`, optionally followed in the same `forward` by `setProtocolVersionDeadline`. The merge derives no
executor leg for it and refuses a core transition or a CTM infrastructure object beside it; `upgrade-governance`
replays it like any other. Verify it with `verify-package` before it is signed (see below).

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
reads the merged `ecosystem.toml` and decides from its calldata whether it drives an upgrade (executor
legs), the one-time bootstrap edge (`migrate()`) or a transition replacement (a `forward` carrying
`replaceUpgradeTransition`). It refuses a package that is none of them or mixes them. For an upgrade it
recovers each leg's executor and object from the calldata and reconciles them with the prepare
summaries (`[core.registry]`, `[ctms.*.registry]`), both ways: a reported object without its leg, a
leg without its reported object, a substituted object or executor, a duplicated leg, a leg carrying
value and any other call to an executor are refused at load. It is read-only and needs nothing but that file, an L1 RPC and the reviewer's inputs.

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
Core-domain and CTM-domain `ProxyUpgradeTransition`s and the `CTMTransition` its legs apply, the
release pair, and the domain executors it runs through (for the bootstrap edge also the migration
and the sequence its calls are derived from). Each `ProxyUpgradeTransition`'s domain is held
against the domain of the leg that applies it, fixed by the leg rather than read from the object. Each is held against its own
construction: the reviewed creation code, run on that object's reviewed constructor arguments,
must land at the object's address. For a write-once object those arguments are the manifest it
serves; for an executor they are the ones its record states (below), and for the bootstrap
sequence the migration and core transition the package names — never the object's own getters,
since a genuine executor built for an attacker's owner answers them exactly like the reviewed one.
That is what establishes the audited CONSTRUCTOR produced it, which a runtime codehash cannot (and
the lifecycle objects set immutables, so no codehash identifies them at all) — so it needs the
reviewed commit built locally
(`cd l1-contracts && forge build`) for the creation code BYTES, and the CREATE2 salts: each prepare
records the salt it deployed under (`create2_factory_salt`, merged under `[core]` and `[ctms.*]`),
and `--create2-salt` adds reviewer-supplied ones (the env's `[contracts] create2_factory_salt` and
`[create2_factory_salts]` entries).
An executor is re-derived from its EXECUTOR RECORD, which is mandatory: the `[upgrade_executors]`
table the run that deployed it wrote (the `ecosystem init` / `ctm init` forge outputs
`script-out/output-deploy-l1.toml` / `output-deploy-ctm.toml`, or a bootstrap package, which carries
its own), passed with the repeatable `--executor-record`. The record's salt and ORIGINAL constructor
arguments re-derive the address; its immutable bindings are still held against the package's values,
and its initial owner is only reported — a fresh ecosystem constructs its executors for the deployer
and nominates governance. An executor without a record is unverified, which is an error. The live
owner and pending owner are checked separately, against the reviewed governance. A bootstrap also requires the CTM's
Bridgehub to be owned by the manifest's governance, since the CTM takes `freezeChain` / `unfreezeChain` from the
Bridgehub's owner too ({protocol-docs/ecosystem-upgrade-coordination.md#freezing-a-chain}). Each write-once object's live code is
also compared with the reviewed build's deployed bytecode of its contract. Every release the package installs is
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
than the stock `L2DefaultUpgrade`, which is then reported for the reviewer to confirm. The
release's own `validate()` is called as well: it reads no state, and it runs on chain when a
transition is built over the release, in the bootstrap's `validate()` and when the CTM installs the
release, so a revert — a codeless `diamondInit`, `genesisUpgrade`, verifier or facet
(`RegistryTargetHasNoCode`), a facet with no selectors (`RegistryEmptySelectors`), a selector two
facets route (`RegistryDuplicateSelector`), or a facet that does not answer `selectors()` (a revert
without data) — fails the run before the vote rather than governance's execution.

**What the objects' members run** is held against the reviewed build too. An L1 member's live code
is compared with the reviewed artifact of each contract its role admits, byte for byte outside the
artifact's immutable slots (`immutableReferences`) — which proves the code, not the values its
constructor wrote into those slots (see the construction records below):

| Member                                                     | Must run                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a release's genesis facets                                 | `AdminFacet`, `GettersFacet`, `MailboxFacet`, `ExecutorFacet`, `MigratorFacet` or `CommitterFacet`                                                                                                                                                                           |
| a release's `diamondInit` / `genesisUpgrade`               | `DiamondInit` / `L1GenesisUpgrade`                                                                                                                                                                                                                                           |
| a release's `verifier`                                     | `MultiProofTestnetVerifier`, `MultiProofVerifier`, `ZKsyncOSTestnetVerifier` or `ZKsyncOSVerifier`, and each sub-verifier it names through `INNER_VERIFIER` / `AIRBENDER_VERIFIER` / `ZISK_RANGE_VERIFIER` / `PLONK_VERIFIER` the reviewed contract of its place in the tree |
| a transition's / the bootstrap migration's `upgradeEngine` | `DefaultUpgrade` / `BootstrapUpgrade`                                                                                                                                                                                                                                        |
| an L2 plan's `delegateComposer`                            | `L2DefaultDelegateCalldataComposer`                                                                                                                                                                                                                                          |
| each proxy row's `implNew`                                 | the contract of the row's slot (`MultisigCommitter` or `ValidatorTimelock` for the timelock)                                                                                                                                                                                 |

A release may carry over the verifier already in force where it departs from — the departing
release's, or for the bootstrap the one the CTM's chains at the departing version run — even when
an earlier build produced it: the prepare pins the live verifier unless the version deploys one, and
an unchanged verifier is not something the upgrade changes. Every other member must be this
build's. `ZiskVerifier`'s snarkJS Plonk backend is built outside this repository, so no reviewed
build describes it: the code at its `PLONK_VERIFIER()` must hash to a runtime pinned in
`tools/verifier-gen/data/ZiSK_plonk_backend.toml` (next to the verification key it renders; how to
recompute it is in `l1-contracts/contracts/state-transition/verifiers/README.md`), and no code, no
applicable pin or another hash fails the run. An L2 member is a ZKsync OS bytecode info, held against
the reviewed hashes' `(blake2s, length, keccak256)`: each row of a release's L2 table must be the
bytecode of the contract its `L2EcosystemContract` slot names (`EmptyContract` for the removed
GWAssetTracker), its system-proxy shell `SystemContractProxy`'s, a plan's delegate
`L2DefaultUpgrade`'s and each extra bytecode some reviewed contract's.

**Each member the package newly installs is held to its construction record.** Every prepare
records each contract it deploys through `deploySimpleContract` or as a proxy implementation
(`[member_deployments]`, merged under `[core]` and `[ctms.*]`: the contract, the CREATE2 factory, the
salt and the exact constructor arguments). A release member the departing release does not name
(at the bootstrap: anything but the verifier the chains run, and the sub-verifiers its tree names),
every engine and composer, each row's `implNew` and the implementation behind a proxy the package
introduces must have one: the reviewed creation code run on the recorded arguments under the
recorded salt, through the deterministic factory, must land at the member, and the arguments must be
exactly their ABI encoding. Each argument is then held against the source the prepare took it from,
re-read independently — never against anything the package supplies:

| Argument                                                                        | Held against                                                                                                                           |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| the L1 chain id (facets)                                                        | the RPC's chain id, which must equal the env's `l1_chain_id` when it declares one                                                      |
| `_isTestnet` (Mailbox, Migrator)                                                | the env's `testnet_verifier`                                                                                                           |
| a Bridgehub                                                                     | the env's `bridgehub_proxy_addr` (or `--expected-bridgehub`); the package's CTM's `BRIDGE_HUB()` and `bridgehub_proxy_addr` must agree |
| an ecosystem proxy (chain asset handler, message root, nullifier, asset router) | the live proxy, discovered through that Bridgehub                                                                                      |
| the WETH token, an ecosystem implementation's owner, the chain cap              | the asset router's `L1_WETH_TOKEN()` and `owner()`, the Bridgehub's `MAX_NUMBER_OF_ZK_CHAINS()`                                        |
| the Admin facet's RollupDAManager                                               | the env's `rollup_da_manager` for the CTM and the `getRollupDAManager()` of a chain on it, which must agree                            |
| the Mailbox's EIP-7702 checker                                                  | a deployed reviewed `EIP7702Checker`                                                                                                   |
| a verifier's sub-verifier                                                       | the address the verifier-tree walk read through its getter                                                                             |
| a new `ChainTypeManager` implementation's `_bridgehub`                          | the reviewed Bridgehub, as above                                                                                                       |
| its other four                                                                  | the values its getter check (below) establishes                                                                                        |

A member without a record, a record that does not re-derive, an argument whose source disagrees and
one nothing establishes each fail the run. The record is untrusted input, so it can only fail: a
record claiming the expected value for a member built over another does not re-derive. The records
no check consulted are listed for information.

**Every proxy row names the proxy of its slot.** Row `i` of a Core-domain inventory is
`L1EcosystemContract` member `i`, of a CTM-domain one or the bootstrap's `CTMContract` member `i`,
and that member's proxy is discovered on chain: the Bridgehub (from the CTM's `BRIDGE_HUB()`, or the
core prepare's `bridgehub_proxy_addr` for a core-only package naming no CTM) and its `assetRouter()`, the router's `L1_NULLIFIER()` and
`nativeTokenVault()`, the Bridgehub's `messageRoot()`, `l1CtmDeployer()`, `chainAssetHandler()` and
`chainRegistrationSender()`, the nullifier's `l1InteropHandler()`; the CTM itself and its
`validatorTimelockPostV29()`, `L1_BYTECODES_SUPPLIER()`, `PERMISSIONLESS_VALIDATOR()` and
`serverNotifierAddress()`. A row naming another proxy, a row in a slot that is no proxy of its
domain, and an inventory whose length is not its enum's each fail the run, and so does a malformed
inventory, which the objects' constructors refuse too: a row with a zero proxy or a zero `expectedOldImpl`, a
self-edge (`expectedOldImpl == implNew`, which applies as a no-op), two rows naming one proxy, and a
`ProxyUpgradeTransition` with no participating row at all (omit the leg instead).

A new `ChainTypeManager` implementation's constructor immutables — `BRIDGE_HUB`, `INTEROP_CENTER`,
`L1_BYTECODES_SUPPLIER`, `PERMISSIONLESS_VALIDATOR`, `L1_INTEROP_FEE_MANAGER` — are masked by the
code comparison, so they are read off the implementation and held against the live CTM's own
getter (unchanged across the swap), else the inventory row of the slot they name, else the proxy
the package reports for that slot (`[ctms.*.state_transition]`) once it is shown to run the
reviewed `TransparentUpgradeableProxy`, with the CTM-domain ProxyAdmin in its EIP-1967 admin slot
and an implementation in its EIP-1967 implementation slot that runs the slot's reviewed contract —
a singleton the upgrade introduces, like the v35 bootstrap's `L1InteropFeeManager`. Such a proxy's
`initialize` calldata is not reviewed. `INTEROP_CENTER` falls back to the L2 built-in
`L2_INTEROP_CENTER_ADDR`; `BRIDGE_HUB` has no fallback. A zero value, or one nothing establishes,
fails the run; `PERMISSIONLESS_VALIDATOR` is written into every new chain once. The
implementation's construction record is held against the same values (its `_bridgehub` against the
reviewed Bridgehub), as an independent second check, and so is the record of the implementation
behind a reported proxy.

`--expected-bridgehub <address>` replaces the env's `bridgehub_proxy_addr` as the Bridgehub the
members' arguments are held against. It exists for harnesses whose scratch L1 the env file does not
describe (the anvil upgrade runner passes the fixture's); a package that will be signed is reviewed
with the env's.

`--contract-hashes <path>` replaces the committed `AllContractsHashes.json` the local build and the
live code are held against. It exists for harnesses that verify deployments of an uncommitted build
(the anvil upgrade runner computes one with `scripts/calculate-hashes.ts --output`); the report then
says it reviews the local build rather than a commit, and a package that will be signed is
reviewed without it.

A transition replacement is held against the transition it replaces rather than the CTM's current
state: the replacement's construction as for any transition, the same source release (the replaced
transition's, not the CTM's current one) and pinned deadline, `upgradeTransition[departure]` still
the expected one and not the replacement, a departure below the CTM's version, a target no earlier
than the replaced one that is the CTM's current release at its version or else the source of the
edge committed onward from it, and the replacement's L2 bytecodes published. A replacement
identical to the replaced transition, one pinning another deadline and one landing earlier are
errors of this review too, and the CTM refuses each of them. The effective deadline
and any `setProtocolVersionDeadline` riding the `forward` are reported. The destination is an
existing release, possibly built by an earlier commit, so neither its genesis nor its members are
judged on this path; the replacement's own engine, composer and L2 bytecodes are.

**Does the signed transaction invoke it?** is answered, for an upgrade, by re-encoding each leg
from the reviewed executor and object and requiring the run — core, then CTM infrastructure, then
CTM transition, each only when present — to appear exactly once, contiguous and in that order; a
swapped order or another call between two legs fails the run. The legs' internal calls are
deliberately not re-derived — the executors derive them on chain from the same pinned objects. Every
other call must be a declared governance external action, matched one for one and in declared order,
with every declaration present, and none may reach the upgrade's authorities (the executors, the
objects, the CTM, either ProxyAdmin) whether declared or not. For the
bootstrap edge the bundle must END with the run `actions()` of the construction-verified sequence
derives, in order — whose last call is `validateApplied()` on the migration, so a failing completion
check reverts the whole bootstrap — and every call before it must be a declared external action to
a target outside the edge's authorities: an extra call to the CTM, a `ProxyAdmin`, an executor or an
object is an error whether declared or not. A replacement's bundle must carry the one `forward`,
sent to the executor that owns the CTM, and nothing else may reach the CTM or its executor.

Around those it checks what the objects cannot answer for themselves: authority bound where the
review says (governance owning each executor with no nomination outstanding, the CTM executor bound
to the reviewed CTM and CTM-domain ProxyAdmin, the core executor to the ecosystem ProxyAdmin, no
binding zero, and each domain still held by its executor), the
live state the upgrade departs from, and readiness — the L2 factory dependencies published on the
CTM's supplier, which the CTM's commit requires (and, for the bootstrap edge, the migration's
`validate()`). Readiness is reported apart
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
