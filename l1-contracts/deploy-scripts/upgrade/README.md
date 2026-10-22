# Upgrade scripts — runbook

How a registry-driven upgrade is prepared, composed, verified, replayed and how chains cross.
Why the pieces look the way they do is in
[the architecture document](../../../docs/registry-driven-upgrades.md); what the executor calls
governance makes do on-chain, and in which order, is in
[the coordination spec](../../../protocol-docs/ecosystem-upgrade-coordination.md). The roles, the
artifacts and the order of the phases are in
[protocol-docs/ecosystem-upgrade.md](../../../protocol-docs/ecosystem-upgrade.md). Start a security
review from the [root README review guide](../../../README.md#reviewing-registry-driven-upgrades).

The Forge scripts in this directory are not run with `forge script` directly in a rollout:
`protocol_ops` (see [protocol-ops/README.md](../../../protocol-ops/README.md)) invokes their entry
points on an Anvil fork and turns the recorded broadcasts into Safe bundles. `chain upgrade` and
`chain set-upgrade-timestamp` go through `AdminFunctions.s.sol`.

## Layout

- `default-upgrade/` — the version-independent prepare pipeline. `DefaultCoreUpgrade` (ecosystem
  side) deploys or reuses each L1 ecosystem implementation against the live one by code identity
  and pins the replacements in a Core-domain `ProxyUpgradeTransition`.
  `DefaultCTMUpgrade` (per-CTM side) deploys the release members the version changes, the
  `CTMTransition` and, when a CTM-domain implementation changes, a CTM-domain
  `ProxyUpgradeTransition`, each independently. Neither emits the executor calls — each is a
  function of an (executor, object) pair the prepares report, and the merge derives them; anything
  else a version needs governance (or an admin) to do goes through `declareExternalAction`
  (`ExternalActionsLib`) and is listed in the output's `external_actions`.
  `DefaultChainUpgrade` is the legacy handed-cut per-chain leg the Foundry integration tests use.
- `v36/` — the v35 -> v36 edge, the first registry-driven release and the template for the next
  one: `CoreUpgrade_v36` declares the changed ecosystem implementations and reinitializes the
  `ChainRegistrationSender` row; `CTMUpgrade_v36` declares the changed release members and opts into
  `DefaultCTMUpgrade.standardL2Side` for its L2 leg ({protocol-docs/l1sload.md#upgrade-from-v35}).
- `v35/` — the v34 -> v35 bootstrap edge: `CoreUpgrade_v35` also deploys the
  `CoreUpgradeExecutor`; `CTMUpgrade_v35` deploys the `CTMUpgradeExecutor`, the
  `RegistryBootstrapMigration` (naming both executors) and the `RegistryBootstrapSequence` over the
  migration and the core transition, and declares every call of the one-time edge by reading it off
  that sequence.
- `SystemContractsProcessing.s.sol` — the L2 force-deployment set shared by genesis and upgrades.
- `EmergencyUpgradeCalldata.s.sol` and its companions — executing a prepared package as an
  emergency upgrade ("Emergency execution" below).

Other one-off scripts of shipped upgrades live on their release branches, not here.

## 1. Inputs

Per-environment inputs are `upgrade-envs/<version>/<env>.toml` (see
`upgrade-envs/v0.35.0-upgrade-system/`), permanent values `upgrade-envs/permanent-values/<env>.toml`.
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
2. The core prepare (`noGovernancePrepare`): each ecosystem implementation reused when it already
   runs the code the current sources produce and redeployed only when the version declares it
   changed, then the Core-domain `ProxyUpgradeTransition` (none when the run deployed no ecosystem
   implementation). Output `[registry]`: `core_transition_addr` (zero when none) and
   `core_upgrade_executor_addr` — the executor read from the live ecosystem `ProxyAdmin`'s owner,
   or deployed by the v35 prepare.
3. Each ZKsync OS CTM prepare, in input order (Era CTMs are skipped): every release member is
   reused when it already runs the code the current sources produce and redeployed only when the
   version names it in `changedReleaseMembers()`; the release itself is new on every version bump
   and reused only by an infrastructure-only edge. Then the transition (validated) unless the
   version declares an infrastructure-only edge, the CTM-domain `ProxyUpgradeTransition` when a
   CTM-domain implementation changed, and — on the bootstrap edge only — the ChainAdmin's half of
   the one-time ServerNotifier handover, rendered from live state. The prepare refuses an upgrade
   with no core transition, no CTM-domain object and no transition. The CTM executor is read
   on-chain (the CTM's owner, bound to it); only the bootstrap prepare takes the core executor
   from the core prepare's output. Output `[registry]`: `ctm_transition_addr`,
   `ctm_infrastructure_transition_addr` (each zero when none), `ctm_release_addr`,
   `bootstrap_migration_addr` (zero unless a bootstrap) and `ctm_upgrade_executor_addr` (nonzero
   whenever one of those objects exists).
4. The ServerNotifier handover calls (bootstrap only), executed on the fork as each target's live
   owner (`UpgradeFull::run_ctm_admin_steps`; see the
   [operations document](../../../docs/upgrade-operations.md#servernotifier-a-one-time-handover-then-an-ordinary-ctm-domain-proxy)).
5. On PUH-governed environments whose release input declares `redeploy_zk_governance = true`, the
   PUH/Guardians redeploy (`zk_governance.rs`). No v35 input declares it.
6. The merge (`upgrade.rs::write_merged_ecosystem_toml`) writes `<env-out>/ecosystem.toml` with ONE
   governance bundle, `[governance_calls] calls`: the merger's own extras (PUH wiring and CTM
   `acceptOwnership` normalization) → the core prepare's declared calls → the executor legs,
   derived from the `[registry]` objects and executors the prepares reported, one contiguous run in
   canonical order (`applyL1Upgrade(core_transition_addr)`,
   `applyInfrastructureUpgrade(ctm_infrastructure_transition_addr)`,
   `applyCTMUpgrade(ctm_transition_addr)`, each only when its object is nonzero; none for a
   bootstrap or a replacement) → the CTM prepare's declared calls. The layout is documented on that
   function. The merge authors nothing else and refuses a prepare's `[governance_calls] calls`
   unless every call is a declared external action — matched by identity, target, value and
   calldata alike, not by headcount (`check_bundle_provenance`).

Every prepare deployment rides the CREATE2 factory; the deployer's Safe bundles and `manifest.json`
land under `--out` (default `upgrade-envs/<version>/output/<env>/protocol-ops/prepare/`). Each
prepare output also records every contract the run deployed through `deploySimpleContract` or as a
proxy implementation — reused deployments included, since the factory returns the existing address —
in `[member_deployments]`, keyed by address: the contract, the CREATE2 factory, the salt and the exact
constructor arguments (`MemberDeploymentsRecord`). The merge carries it under `[core]` and
`[ctms.<key>]`, and the review ([§4](#4-verify)) re-derives every member the package newly
installs from it.

## 3. Review

The reviewable content is the objects, not the calldata. For each object in `[registry]`, read the
manifest (`getManifest()`) and compare `manifestHash()` with the audited manifest; that the
objects at those addresses were built from it is what step 4 establishes. Then read
`external_actions`: one `[[external_actions]]` entry per call the objects do not describe,
carrying the call itself (`target`, `value`, `data`) beside its `phase` (`governance` or `admin`),
`label` and the `authority` that performs it. A registry-driven upgrade has none beyond the
merger's extras; the bootstrap edge declares its whole one-time edge this way.

## 4. Verify

```sh
cargo run --release --bin protocol_ops -- ecosystem verify-bootstrap \
  --ecosystem-toml <env-out>/ecosystem.toml --l1-rpc-url <rpc> --expected-governance-owner 0x... \
  --env <env> \
  --executor-record <the bootstrap package, or the ecosystem/ctm init outputs, that deployed the executors> \
  [--create2-salt <a salt the package does not record>]
```

Run it before every vote: governance approves the exact deployed objects, and this is where their
construction is established ("Provenance and validation" in the architecture document).
`verify-bootstrap` (alias `verify-package`, `upgrade_verification/registry/`) verifies a
registry-driven package against live L1 and decides from the package itself which kind it is: an
upgrade driven through the domain executors' legs, the one-time bootstrap edge, or the replacement
of a committed transition (prepared by `DefaultTransitionReplacement`). It checks every object's
construction (the write-once objects from their manifests, the bootstrap sequence from the objects
it was constructed over — under the salts each prepare leg records in its output
(`create2_factory_salt`) — and the executors from the `[upgrade_executors]` record of the run that
deployed them, without which an executor is unverified), that every object and every member it
names runs the reviewed build's code for its role, that every member the package newly installs
re-derives from its `[member_deployments]` record with each constructor argument equal to the live or
env value the prepare took it from (without a record it is unverified), that `ZiskVerifier`'s Plonk
backend runs the pinned runtime, that every proxy row names its slot's proxy,
the bound authority and the owner the upgrade is driven by, every row's departing implementation,
that chains crossing the edge keep the system-proxy logic new chains get, readiness,
and that the calldata governance signs invokes the reviewed upgrade, in canonical order, and
nothing else. What it
checks and deliberately does not is in
[`docs/ai-review/docs/protocol-ops.md`](../../../docs/ai-review/docs/protocol-ops.md).

## 5. Deployer broadcast

Replay the deployer bundles under the EOA keys, one transaction per call. Do not send a deployer
bundle as one Safe UI batch: its deploys together exceed EIP-7825's 2^24 per-transaction cap, and
after Glamsterdam single deploys exceed it on their own (their state gas is outside the cap), which
`upgrade-broadcast` accounts for:

```sh
cargo run -p protocol_ops -- ecosystem upgrade-broadcast --manifest <out>/manifest.json --l1-rpc-url <rpc> --key 0x<addr>=0x<key>
```

## 6. Governance

```sh
cargo run -p protocol_ops -- ecosystem upgrade-governance --env <env> --l1-rpc-url <rpc>
```

replays the governance bundle of `<env-out>/ecosystem.toml` on a fork as governance, fails unless
the fork is left in the state the package describes
([where each check lives](../../../protocol-docs/ecosystem-upgrade.md#where-each-check-lives)), and
emits the governance Safe bundle; `ecosystem governance-toml-to-simulator` emits the transaction-simulator JSON. On the
bootstrap edge the bundle ends with the edge's completion check
(`RegistryBootstrapMigration.validateApplied()`), so the replay itself reverts unless the edge completed.
Monitoring and recovery: the [operations document](../../../docs/upgrade-operations.md).

## Emergency execution

On a PUH-governed environment (`governance_kind = "puh"`) the package can run as an emergency
upgrade instead of step 6: `EmergencyUpgradeBoard.executeEmergencyUpgrade` has the
`ProtocolUpgradeHandler` execute the calls at once. The scripts make ONE emergency proposal of the
governance bundle in `<env-out>/ecosystem.toml` (`[governance_calls] calls`).

1. Dry run on a fork before any approval is collected. It impersonates the board, so only the
   signature check is skipped:

   ```sh
   forge script deploy-scripts/upgrade/VerifyEmergencyUpgrade.s.sol:VerifyEmergencyUpgrade \
     --sig 'verify(address,string)' <puh> <env-out>/ecosystem.toml --rpc-url <fork>
   ```

2. Emit the calldata. This step is read-only and needs no key:

   ```sh
   forge script deploy-scripts/upgrade/EmergencyUpgradeCalldata.s.sol:EmergencyUpgradeCalldata \
     --sig 'run(address,string)' <puh> <env-out>/ecosystem.toml --rpc-url <l1>
   ```

   It prints one `approveHash` transaction per required approval: the first `EIP1271_THRESHOLD`
   members of the Guardians, then of the Security Council, then the ZK Foundation Safe. The one EOA
   that owns every approving Safe sends them. The board call comes last and any account may send it.
   The script refuses a board whose approving Safes are not 1-of-1 Safes of that EOA, the staging
   setup, because the "approved hash" marker it emits stands for that owner's approval only.

Gotchas:

- **CTM-admin calls.** The `[ctm_admin_calls]` of a bootstrap (the ServerNotifier handover) are not
  governance calls. They must land before the proposal.
- **Governance redeploy.** In a release that redeploys the governance set (`redeploy_zk_governance`),
  the rewiring runs inside the proposal. The proposal is still approved through the board the
  handler names when the calldata is emitted.

Companions:

- `VerifyEmergencyApproveHash.s.sol` (`run(address)`, fork only) checks that the board accepts the
  approved-hash route, using an empty proposal.
- `SecurityCouncilEmergencyStageUpgrade.s.sol` and `SecurityCouncilApproveStageUpgrade.s.sol` cover
  the SIGNED route through `Utils`. They need the Safes' owner key and read the env vars
  `PROTOCOL_UPGRADE_HANDLER`, `PRIVATE_KEY` and `UPGRADE_ID`. The first executes an empty emergency
  proposal; the second records the Security Council's approval of a standard-path proposal id.
- A fix outside a prepared package — restoring a single CTM-domain proxy, say — is a
  `CTMUpgradeExecutor.forward` call, packaged by the same builder from a file whose
  `[governance_calls] calls` (an `abi.encode(Call[])`) carries it.

Tests: `test/foundry/l1/integration/emergency-upgrade/`.

## 7. Chain crossing

After the governance proposal, each chain crosses on its own: `protocol-ops chain upgrade` runs
`AdminFunctions.upgradeChainFromCTM`, which selects the cut-reading entrypoint for a chain at v35
or later and reconstructs a cut only for a chain that predates it (`UpgradeChainCall.requiresCut`).
Who may trigger the crossing and when is `CTMUpgradeExecutor.upgradeChain`'s policy (architecture
document, "Flow: upgrading"). `chain set-upgrade-timestamp` schedules it on the ServerNotifier
({protocol-docs/upgrade-scheduling.md}); `chain set-da-validator-pair` restores the DA pair the
upgrade resets.

On the v35 bootstrap edge `upgradeChain` does not apply: the departing version has no transition.
A chain's admin crosses it with the migration's `upgradeCut()`, and governance can cross a chain
itself with `ChainTypeManager.upgradeChainFromVersion(chainId, oldVersion, cut)` through
`CTMUpgradeExecutor.forward`, a passthrough kept only until no chain can depart a pre-v35 version.

**Chain admins behind an `AccessControlRestriction`.** Every crossing after the bootstrap edge calls
the chain's two-argument `upgradeChainFromVersion(address,uint256)` (`0x03129ad9`) instead of the
cut-taking `upgradeChainFromVersion(address,uint256,DiamondCutData)` (`0x3b6d7534`). A role the
restriction requires for the old selector does not carry over: before the chain's first crossing
after v35, the restriction's default admin sets it for the new one
(`setRequiredRoleForCall(chainAddress, 0x03129ad9, role)`); until then only the default admin can
send the crossing.

Server and monitoring consumers must read the final transaction through
`transition.l2UpgradeTx(bridgehub, chainId)` or `bootstrap.l2UpgradeTx(chainId)`. These views
use the same chain-context composition as execution; there is no
`getL2UpgradeTxData(bridgehub, chainId, zksyncOS, data)`, so its external consumers must be updated
and verified before rollout.

## Preparing the scripts for a new upgrade

Open the release with `yarn new-release <name>` (repo root): it bumps the genesis protocol version,
creates `upgrade-envs/v0.<minor>.0-<name>/` from the current release's inputs with fresh salts,
moves `current_upgrade_env_dir!` and the prepare's default script paths
(`protocol-ops/src/common/forge/scripts/mod.rs`), and generates `v<minor>/CoreUpgrade_v<minor>` and
`CTMUpgrade_v<minor>` as plain subclasses of the default scripts unless the branch already carries
them. The header of `scripts/new-release.ts` lists what it changes and what it leaves to you.

Start from `v36/`: inherit the `Default*Upgrade` bases, override `deployNew*Contracts` with the
contracts the release changes, name every release member you replace in `changedReleaseMembers()`,
and keep everything else derived.

**Declare what the upgrade is.** `DefaultCTMUpgrade.upgradeKind()` returns `ChainRelease` by
default — the edge deploys the upgrade engine and a `CTMTransition`, and the protocol version
moves. An upgrade that only replaces ecosystem or CTM-domain singletons behind their proxies
overrides it with `InfrastructureOnly`: no transition, no engine, no cut, only the proxy upgrade
transitions, so a `ValidatorTimelock` swap costs no fleet-wide version adoption. The
declaration is a version-script hook rather than an input key for the same reason
`changedReleaseMembers()` is one — what an upgrade sets out to change is a property of the release,
identical on every environment — and the version numbers are checked AGAINST it: an
infrastructure-only edge whose input names another version is refused, and so is a chain-release
edge whose input forgot to move it.

**Every implementation the run deploys must be installed.** Preparation refuses an implementation
it deployed that no inventory row installs, unless the version names its slot in
`uninstalledCoreDeployments()` / `uninstalledCTMDeployments()` — a deployment nothing references is
either a swap that will silently not ship or a row builder nobody wrote, and both look like a
successful prepare from the output alone.

A release whose L2 built-ins change must also author the L2
side (`authorL2Side`: delegate/extra bytecode infos, the pinned composer and the bytecode
artifacts needed to publish the constructed plan’s factory dependencies — `CTMUpgrade_v35` shows the shape) because the release-pair derivation puts the
changed built-ins in the L2 leg. Any governance or admin call the version needs beyond the
executor legs is a `declareExternalAction`.

Register new L2 built-ins in `SystemContractsProcessing.s.sol` and, for the genesis path, in the
genesis generator, so that upgraded and freshly created chains match
([`docs/ai-review/docs/genesis-and-upgrades.md`](../../../docs/ai-review/docs/genesis-and-upgrades.md)).

## Testing an upgrade end to end

- `test/foundry/l1/integration/UpgradeTest_Local.t.sol` — the bootstrap edge through the real
  prepare pipeline, in-forge, including the chain crossing via the legacy cut-taking leg.
- `test/foundry/l1/integration/UpgradeTestRecurring_Local.t.sol` — RECURRING prepares on the
  ecosystem that fixture leaves behind: the infrastructure-only, chain-release, mixed and
  three-leg shapes preparation can emit, each run as its ordered bundle, and the ones it must
  refuse (an upgrade that changes nothing, either version/kind contradiction, an orphaned
  deployment on either domain).
- `test/anvil-interop/run-upgrade-test.ts` — the bootstrap driven end to end by
  protocol-ops against the frozen departing-version chain states, then two registry-driven hops
  on the same chains: a same-minor verifier patch (run with the bootstrap's L2 transaction still
  pending, required to derive no facet cut) and the v36 minor hop (required to reuse every live
  release member). Each hop's merged artifact is verified and asserted to carry its executor legs
  as one contiguous run in canonical order, and one transaction must emit every leg's domain event,
  in order.
- `test/anvil-interop/run-recurring-upgrade-test.ts` — the registry-driven hop with objects
  deployed by the harness itself.
- `test/foundry/l1/unit/concrete/Upgrades/registry/` — the bundle-execution (all legs in one
  `Governance` proposal), executor-domain, executor, transition-replacement,
  ServerNotifier-handover and individual-upgrade suites.

Script retirement — what tooling still decides and the batches that move it on-chain — is
tracked in [the retirement plan](../../../docs/upgrade-script-retirement.md).

## Rules

- Never use `try`/`catch` or `staticcall` in these scripts. A revert means the script is being
  run at the wrong time or against the wrong state; fix that instead of masking it.
- Read addresses from L1 (through the Bridgehub) rather than adding input fields; the inputs a
  release needs are listed in [`upgrade-envs/README.md`](../../upgrade-envs/README.md).
- Every release ships with the anvil-interop upgrade test (`test/anvil-interop/run-upgrade-test.ts`,
  above), which runs these scripts end to end on the previous release's chain states.
