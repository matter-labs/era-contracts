# Upgrade scripts — runbook

How a registry-driven upgrade is prepared, composed, verified, replayed and how chains cross.
Why the pieces look the way they do is in
[the architecture document](../../../docs/registry-driven-upgrades.md); what the coordinator's
three stages do on-chain is in
[the coordinator spec](../../../protocol-docs/ecosystem-upgrade-coordination.md). Start a security
review from the [root README review guide](../../../README.md#reviewing-registry-driven-upgrades).

## Layout

- `default-upgrade/` — the version-independent prepare pipeline. `DefaultCoreUpgrade` (ecosystem
  side) deploys the new ecosystem implementations and pins them in a `CoreRegistry`.
  `DefaultCTMUpgrade` (per-CTM side) deploys the release members the version changes, a
  `GovernanceUpgradeTimer` bound to the coordinator and the `CTMTransition`. Neither emits a
  lifecycle call; anything else a version needs governance (or an admin) to do goes through
  `declareExternalAction` (`ExternalActionsLib`) and is listed in the output's `external_actions`.
  `DefaultChainUpgrade` is the legacy handed-cut per-chain leg the Foundry integration tests use.
- `ComposeUpgradeOperation.s.sol` — the compose step: deploys the `EcosystemUpgradeOperation` over
  the core prepare's registry and every CTM prepare's `(executor, transition)` leg and emits the
  three governance calls, `EcosystemUpgradeExecutor.stage0/1/2(operation)`.
- `v35/` — the first registry-driven release and the template for the next one: `CoreUpgrade_v35`
  deploys one fresh `L1MessageRoot`; `CTMUpgrade_v35` overrides nothing.
- `v34/` — the bootstrap edge: `CoreUpgrade_v34` also deploys the `CoreUpgradeExecutor` and the
  coordinator; `CTMUpgrade_v34` deploys the `CTMUpgradeExecutor` (constructed answering to that
  coordinator) and the `RegistryBootstrapMigration`, and both declare every call of the one-time
  edge as external actions.
- `SystemContractsProcessing.s.sol` — the L2 force-deployment set shared by genesis and upgrades.

One-off scripts of shipped upgrades live on their release branches, not here.

## 1. Inputs

Per-environment inputs are `upgrade-envs/<version>/<env>.toml` (see
`upgrade-envs/v0.34.0-registry/`), permanent values `upgrade-envs/permanent-values/<env>.toml`.
Keep inputs minimal — the prepare reads the departing version, the live implementations, the
CTM's owner and the ecosystem `ProxyAdmin`'s owner from L1. One input cannot be derived and must
be carried forward from the previous prepare's output: `[contracts] eip7702_checker`
(`upgrade-envs/README.md` explains why omitting it replaces the Mailbox facet on every chain).

## 2. Prepare and compose

```sh
cargo run -p protocol_ops -- ecosystem upgrade-prepare-all \
  --env <env> --l1-rpc-url <rpc> --deployer-address <EOA>
```

On one anvil fork of L1, in this order:

1. `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernance` — the ownership precondition.
2. The core prepare (`noGovernancePrepare`): implementations, then `CoreRegistry` (none when the
   run deployed no ecosystem implementation). Output `[registry]`: `core_registry_addr`,
   `core_upgrade_executor_addr`, `ecosystem_upgrade_executor_addr` — the executor and coordinator
   read from the live `ProxyAdmin` owner, or deployed by the v34 prepare.
3. Each ZKsync OS CTM prepare, in input order (Era CTMs are skipped): every release member is
   reused when it already runs the code the current sources produce and redeployed only when the
   version names it in `changedReleaseMembers()`; a release whose members all reused is reused
   itself. Then the timer, the transition (validated, and checked against the bound executor's
   `TRANSITION_CODEHASH`), and the ServerNotifier admin call rendered from the pinned row. Output
   `[registry]`: `ctm_transition_addr`, `ctm_release_addr`, `upgrade_timer_addr`,
   `ctm_upgrade_executor_addr`, `bootstrap_migration_addr` (zero unless a bootstrap).
4. The ServerNotifier admin call, executed on the fork as the ChainAdmin
   (`UpgradeFull::run_ctm_admin_steps`; see the
   [lifecycle document](../../../docs/upgrade-stage-lifecycle.md#servernotifier-a-row-under-a-foreign-admin)).
5. The compose step (`upgrade_inner.rs::compose_operation`): skipped when no CTM prepare emitted a
   transition (a bootstrap edge); a mix of transition-bearing and transition-less CTM outputs is
   refused. It re-checks every stage-0 binding (each domain's `coordinator()`, each object against
   the codehash its executor pins, each timer's `TIMER_GOVERNANCE`) so a drift fails here, not
   with the upgrade already reviewed. Output `[registry]`: `operation_addr`, `coordinator_addr`.
6. On PUH-governed environments, the PUH/Guardians redeploy (`zk_governance.rs`); when
   `[new_gateway]` is configured, `GatewayVotePreparation`.
7. The merge (`upgrade.rs::write_merged_ecosystem_toml`) writes `<env-out>/ecosystem.toml`: each
   stage bundle is core actions → the coordinator's `stageN(operation)` → CTM actions, in source
   order, followed by the merger's own appends (PUH wiring and CTM `acceptOwnership` normalization
   in stage 0, the new-Gateway bundle in stage 2). The layout is documented on that function.
   The merge composes nothing and refuses a bundle whose calls are not all either the compose
   step's stage call or a declared external action (`check_bundle_provenance`,
   `check_operation_bundle`).

Every prepare deployment rides the CREATE2 factory; the deployer's Safe bundles and `manifest.json`
land under `--out` (default `upgrade-envs/<version>/output/<env>/protocol-ops/prepare/`).

## 3. Review

The reviewable content is the objects, not the calldata. For each object in `[registry]`, read the
manifest (`getManifest()`) and compare `manifestHash()` with the audited manifest; the executors
enforce type provenance (codehash) and the objects enforce their pins at execution. Then read
`external_actions`: every line is a call the objects do not describe, with its phase, label,
target, selector and the authority that performs it. A registry-driven upgrade has none beyond
the merger's appends; the bootstrap edge declares its whole one-time edge this way.

## 4. Verify

```sh
cargo run --release --bin protocol_ops -- ecosystem verify-bootstrap \
  --ecosystem-toml <env-out>/ecosystem.toml --l1-rpc-url <rpc> --expected-governance-owner 0x...
```

`verify-bootstrap` (`upgrade_verification/versions/v34/`) verifies a v34 bootstrap package
against live L1 — object provenance, the manifest's pins, the bound authority and the owner it
lands on, every row's departing implementation, and the stage calldata shape. What it checks and
deliberately does not is in [`docs/ai-review/docs/protocol-ops.md`](../../../docs/ai-review/docs/protocol-ops.md).
A recurring registry-driven package (an operation over transitions) has no verifier yet; the
compose step's checks and `protocol-ops`' provenance invariant are what gate it today.
`ecosystem verify-upgrade` is the pre-registry (v31) calldata verifier and does not apply.

## 5. Deployer broadcast

Execute the deployer bundles through the Safe UI, or replay them under the EOA keys:

```sh
cargo run -p protocol_ops -- ecosystem upgrade-broadcast --manifest <out>/manifest.json --l1-rpc-url <rpc> --key 0x<addr>=0x<key>
```

## 6. Governance

```sh
cargo run -p protocol_ops -- ecosystem upgrade-governance --env <env> --l1-rpc-url <rpc>
```

replays stages 0, 1 and 2 of `<env-out>/ecosystem.toml` on a fork as governance and emits the
governance Safe bundle; `ecosystem governance-toml-to-simulator` emits the transaction-simulator
JSON. On the real chain the stages are separate proposals: stage 0 starts each distinct
transition timer once, stage 1 is admissible once the timers' deadlines have passed, stage 2 after stage 1. A
lifecycle that cannot complete is cleared with `EcosystemUpgradeExecutor.abandonPendingOperation`
(see the lifecycle document for what that leaves behind).

## 7. Chain crossing

After stage 1, each chain crosses on its own: `protocol-ops chain upgrade` runs
`AdminFunctions.upgradeChainFromCTM`, which selects the cut-reading entrypoint for a chain at v34
or later and reconstructs a cut only for a chain that predates it (`UpgradeChainCall.requiresCut`).
Who may trigger the crossing and when is `CTMUpgradeExecutor.upgradeChain`'s policy (architecture
document, "Flow: upgrading"). `chain set-upgrade-timestamp` schedules it on the ServerNotifier
({protocol-docs/upgrade-scheduling.md}); `chain set-da-validator-pair` restores the DA pair the
upgrade resets.

Server and monitoring consumers must read the final transaction through
`transition.l2UpgradeTx(bridgehub, chainId)` or `bootstrap.l2UpgradeTx(chainId)`. These views
use the same chain-context composition as execution. The former
`getL2UpgradeTxData(bridgehub, chainId, zksyncOS, data)` API is removed; updating and verifying
external consumers is required before rollout.

## Preparing the scripts for a new upgrade

Start from `v35/`: inherit the `Default*Upgrade` bases, override `deployNew*Contracts` with the
contracts the release changes, name every release member you replace in `changedReleaseMembers()`,
and keep everything else derived. A release whose L2 built-ins change must also author the L2
side (`authorL2Side`: delegate/extra bytecode infos, the pinned composer and the bytecode
artifacts needed to publish the constructed plan’s factory dependencies — `CTMUpgrade_v34` shows the shape) because the release-pair derivation puts the
changed built-ins in the L2 leg. Any governance or admin call the version needs beyond the three
coordinator calls is a `declareExternalAction`.

## Testing an upgrade end to end

- `test/foundry/l1/integration/UpgradeTestv34_Local.t.sol` — the bootstrap edge through the real
  prepare pipeline, in-forge, including the chain crossing via the legacy cut-taking leg.
- `test/anvil-interop/run-v33-to-v34-upgrade-test.ts` — the bootstrap driven end to end by
  protocol-ops against the frozen departing-version chain states, then two registry-driven hops
  on the same chains: a same-minor verifier patch (run with the bootstrap's L2 transaction still
  pending, required to derive no facet cut) and the v35 minor hop (required to reuse the live
  release). Each hop's merged artifact is asserted to be exactly the three coordinator calls.
- `test/anvil-interop/run-v34-to-v35-upgrade-test.ts` — the registry-driven hop with objects
  deployed by the harness itself.
- `test/foundry/l1/unit/concrete/Upgrades/registry/` — the lifecycle, coordination, executor,
  foreign-admin-row and individual-upgrade suites.

Script retirement — what tooling still decides and the batches that move it on-chain — is
tracked in [the retirement plan](../../../docs/upgrade-script-retirement.md).
