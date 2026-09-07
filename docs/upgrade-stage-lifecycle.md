# Upgrade stage lifecycle: moving the scripted stages on-chain

Companion to [registry-driven-upgrades.md](registry-driven-upgrades.md). That document describes
the objects (release, transition, core registry, bootstrap migration) and the bound executors. This
one covers what still sits OUTSIDE them: the three-stage governance flow is today COMPOSED by the
prepare scripts (`l1-contracts/deploy-scripts/upgrade/`) and MERGED by `protocol-ops`. Governance
therefore still reviews a script-produced concatenation of calldata, and the ordering and
participation of the objects in an upgrade is decided off-chain.

The test that decides whether a piece of tooling belongs here: does it ENCODE an already-defined
on-chain operation (compile, deploy, publish bytecodes, inspect objects, submit transactions), or
does it DECIDE what the upgrade does (which actions, in which order, with which extra calls)? Only
the latter is migrated.

Section 1 is the extracted specification of current behaviour — the baseline the migration is
proven against. Section 2 is the outer orchestration layer. Section 3 lists every remaining place
where scripts still define behaviour. Sections 4–6 are the target model, its authority resolution
and the proof obligations. The first change is deliberately "existing behaviour moved on-chain";
simplifications (e.g. dropping pause/unpause on a no-Gateway ecosystem) come after, behind the same
stage interface.

## 1. Current stage behaviour (specification and test baseline)

Source of truth for this section: `DefaultCoreUpgrade.s.sol`, `DefaultCTMUpgrade.s.sol`, their v34
overrides `CoreUpgrade_v34.s.sol` / `CTMUpgrade_v34.s.sol`, and the merge in
`protocol-ops/src/commands/ecosystem/upgrade.rs`.

Each governance stage is ONE bundle executed by the protocol governance (`ProtocolUpgradeHandler`,
"PUH", or the legacy `Governance` contract), so `msg.sender` for every call below is the governance
address unless stated otherwise. The merged order within a stage is fixed by protocol-ops:

```
stageN = core.stageN ++ ctm.stageN [++ extraStage0 (stage 0 only)] [++ newGatewayBundle (stage 2 only)]
```

"Recurring" means every registry-driven upgrade does it; "bootstrap-only" means it belongs to the
one-time v33 → v34 entry edge and must NOT be carried by future transitions.

### Stage 0 — preparation

| #   | Action                                                                                                                                                 | Target                                       | Required authority                                 | Inputs (source)                                                                                                                                                                       | Script                                                                                                                         | Scope                                                       |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| 0.1 | `pauseMigration()`                                                                                                                                     | `L1ChainAssetHandler` proxy                  | CAH `owner` (= governance)                         | CAH address (Bridgehub discovery)                                                                                                                                                     | `DefaultCoreUpgrade.preparePauseGatewayMigrationsCall`                                                                         | recurring                                                   |
| 0.2 | version-specific core stage-0 calls                                                                                                                    | —                                            | —                                                  | —                                                                                                                                                                                     | `prepareVersionSpecificStage0GovernanceCallsL1`                                                                                | empty in v34                                                |
| 0.3 | ecosystem-admin calls                                                                                                                                  | —                                            | —                                                  | —                                                                                                                                                                                     | `prepareDefaultEcosystemAdminCalls`                                                                                            | empty                                                       |
| 0.4 | version-specific CTM stage-0 calls                                                                                                                     | —                                            | —                                                  | —                                                                                                                                                                                     | `DefaultCTMUpgrade.prepareVersionSpecificStage0GovernanceCallsL1`                                                              | empty in v34                                                |
| 0.5 | `startTimer()`                                                                                                                                         | `GovernanceUpgradeTimer` (fresh per upgrade) | `TIMER_GOVERNANCE` (`onlyTimerAdmin`) = governance | timer address (prepare output); ctor `(initialDelay = config.governanceUpgradeTimerInitialDelay, maxAdditionalDelay = 2 weeks, timerGovernance = governance, owner = ecosystemAdmin)` | `prepareGovernanceUpgradeTimerStartCall`, `getCreationCalldata("GovernanceUpgradeTimer")`                                      | recurring                                                   |
| 0.6 | PUH self-upgrade: `ProxyAdmin.upgradeAndCall(puh, newImpl, "")`, `PUH.updateSecurityCouncil`, `PUH.updateGuardians`, `PUH.updateEmergencyUpgradeBoard` | PUH `ProxyAdmin`, PUH proxy                  | PUH (self)                                         | zk-governance deploy outputs                                                                                                                                                          | `protocol-ops … zk_governance::deploy_puh_guardians` → `extra_stage0`                                                          | **separate scope** (governance self-upgrade)                |
| 0.7 | `Ownable2Step.acceptOwnership()` per CTM whose `pendingOwner == governance`                                                                            | each CTM proxy                               | governance                                         | live ownership scan                                                                                                                                                                   | `AdminFunctions.ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps` → `pre-governance-accept-ownerships.toml` → `extra_stage0` | environment repair; not part of the upgrade's own behaviour |

The timer's `deadline` can be EXTENDED after stage 0 by the timer `owner` (the ecosystem admin,
`changeDeadline`, capped at `maxDeadline = deadline + 2 weeks`). That right is separately governed
and must stay explicit.

### Stage 1 — execution

| #     | Action                                                                                                 | Target                                                                        | Required authority                                                                   | Inputs (source)                                                            | Script                                                         | Scope                                                                                     |
| ----- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 1.1   | `pauseMigration()` re-asserted (the EUB path's built-in pre-step unpauses)                             | CAH proxy                                                                     | CAH owner                                                                            | as 0.1                                                                     | `DefaultCoreUpgrade.prepareStage1GovernanceCalls`              | recurring                                                                                 |
| 1.2   | `Ownable.transferOwnership(ecosystemUpgradeExecutor)`                                                  | ecosystem `ProxyAdmin`                                                        | its owner (governance)                                                               | executor address (prepare output)                                          | `CoreUpgrade_v34.prepareUpgradeProxiesCalls`                   | **bootstrap-only** (one-time handover)                                                    |
| 1.3   | `EcosystemUpgradeExecutor.applyL1Upgrade(coreRegistry)`                                                | ecosystem executor                                                            | executor `owner` (governance)                                                        | `CoreRegistry` address (prepare output; content pinned in its constructor) | same                                                           | recurring                                                                                 |
| 1.4   | core `provideSetNewVersionUpgradeCall`                                                                 | —                                                                             | —                                                                                    | —                                                                          | —                                                              | empty                                                                                     |
| 1.5   | version-specific core stage-1                                                                          | —                                                                             | —                                                                                    | —                                                                          | `prepareVersionSpecificStage1GovernanceCallsL1`                | empty (the in-forge v34 test overrides it to nothing)                                     |
| 1.6   | `checkDeadline()`                                                                                      | timer                                                                         | any (view)                                                                           | timer address                                                              | `prepareGovernanceUpgradeTimerCheckCall`                       | default recurring; v34: absorbed by `migrate()`/`validate()`                              |
| 1.7   | `checkMigrationsPaused()`                                                                              | `UpgradeStageValidator` (fresh per upgrade; ctor `(ctm, newProtocolVersion)`) | any (view)                                                                           | validator address                                                          | `prepareCheckMigrationsPausedCalls`                            | default recurring; v34: absorbed (the CTM's version commit reverts `MigrationsNotPaused`) |
| 1.8   | `ProxyAdmin.upgrade(ctmProxy, newCtmImpl)`                                                             | CTM-domain `ProxyAdmin`                                                       | its owner                                                                            | prepare outputs                                                            | `prepareUpgradeCTMCalls`                                       | default recurring; v34: a source-checked row of the bootstrap manifest                    |
| 1.9   | new-chain creation params                                                                              | —                                                                             | —                                                                                    | —                                                                          | `prepareNewChainCreationParamsCall`                            | empty since v32 (release-driven genesis)                                                  |
| 1.10  | `setNewVersionUpgrade(cut, old, deadline = max, new)`, `setReleaseCodehash(h)`, `setCurrentRelease(r)` | CTM proxy                                                                     | CTM `owner`                                                                          | cut (script-composed), release (prepare output)                            | `provideSetNewVersionUpgradeCall`                              | default recurring (legacy form); v34: inside `migrate()`                                  |
| 1.11  | DA validator update                                                                                    | —                                                                             | —                                                                                    | —                                                                          | `prepareDAValidatorCall`                                       | body commented out — not a missing migration                                              |
| 1.12a | `Ownable2Step.transferOwnership(bootstrapMigration)`                                                   | CTM proxy                                                                     | CTM owner (governance)                                                               | migration address (prepare output)                                         | `CTMUpgrade_v34.prepareVersionSpecificStage1GovernanceCallsL1` | **bootstrap-only**                                                                        |
| 1.12b | `Ownable2Step.transferOwnership(bootstrapMigration)`                                                   | CTM-domain `ProxyAdmin`                                                       | its owner (governance)                                                               | same                                                                       | same                                                           | **bootstrap-only**                                                                        |
| 1.12c | `RegistryBootstrapMigration.migrate()`                                                                 | migration                                                                     | permissionless (state-gated: both ownerships held, timer deadline passed, pins hold) | manifest (constructor-pinned)                                              | same                                                           | **bootstrap-only**                                                                        |

`migrate()` performs, in one transaction: `acceptOwnership()` on the CTM; `validate()` (authority
held, executor bound to CTM + ProxyAdmin, departing version, rows at `expectedOldImpl`, pins,
`timer.checkDeadline()`, factory deps published); CTM-domain proxy rows through the ProxyAdmin
(the CTM's own implementation among them); `setNewVersionUpgrade` (legacy cut-taking form; reverts
unless migrations are paused); `setReleaseCodehash`; `setCurrentRelease`; hands the CTM (two-step,
completed through `CTMUpgradeExecutor.acceptCTMOwnership()`) and the ProxyAdmin to the bound
executor.

### Stage 2 — completion and restoration

| #   | Action                                                                             | Target                      | Required authority | Inputs (source)           | Script                                                          | Scope                                                                                           |
| --- | ---------------------------------------------------------------------------------- | --------------------------- | ------------------ | ------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| 2.1 | `EcosystemUpgradeExecutor.validateUpgradeApplied(coreRegistry)`                    | ecosystem executor          | any (view)         | `CoreRegistry` address    | `CoreUpgrade_v34.prepareVersionSpecificStage2GovernanceCallsL1` | recurring                                                                                       |
| 2.2 | `unpauseMigration()`                                                               | CAH proxy                   | CAH owner          | as 0.1                    | `DefaultCoreUpgrade.prepareUnpauseGatewayMigrationsCall`        | recurring                                                                                       |
| 2.3 | `checkProtocolUpgradePresence()`                                                   | validator                   | any (view)         | validator address         | `prepareCheckUpgradeIsPresent`                                  | default recurring; v34: empty (subsumed by 2.4)                                                 |
| 2.4 | `RegistryBootstrapMigration.validateApplied()`                                     | migration                   | any (view)         | —                         | `CTMUpgrade_v34.prepareVersionSpecificStage2GovernanceCallsL1`  | **bootstrap-only** (the recurring equivalent is `CTMUpgradeExecutor.validateTransitionApplied`) |
| 2.5 | `checkMigrationsUnpaused()`                                                        | validator                   | any (view)         | validator address         | `prepareCheckMigrationsUnpausedCalls`                           | recurring (v34 keeps it)                                                                        |
| 2.6 | new-Gateway bring-up bundle (`GatewayVotePreparation.governance_calls_to_execute`) | Bridgehub, CTM, notifier, … | governance         | `[new_gateway]` env block | `protocol-ops write_merged_ecosystem_toml`                      | **deferred** (Gateway out of scope)                                                             |

Note the ordering inside stage 2: the core chunk (2.1, 2.2) precedes the CTM chunk (2.3–2.5), so
`unpauseMigration` runs BEFORE `checkMigrationsUnpaused` — the check verifies the restoration in
the same bundle. Completion checks (2.1, 2.4) run before the restoration (2.2).

### Separately emitted admin actions (not governance stages)

| #   | Action                                                                                   | Target                                                                                                                                                                                            | Required authority                                                           | Script                                                                                   | Scope                                                                                      |
| --- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| A.1 | `ProxyAdmin.upgrade(serverNotifierProxy, newImpl)`                                       | the notifier's OWN `ProxyAdmin` (deployed with `owner = ctmAddresses.chainAdmin`, i.e. the CTM's `ChainAdmin` contract — `DeployCTM.s.sol` `deployWithCreate2AndOwner("ProxyAdmin", chainAdmin)`) | `ChainAdmin` (executes as a multicall; its own owner is separately governed) | `DefaultCTMUpgrade.prepareDefaultCTMAdminCalls` → `[ctm_admin_calls]` in the output TOML | recurring whenever the notifier implementation changes; **outside both inventories today** |
| A.2 | `ServerNotifier.setUpgradeTimestamp(chainId, ts)`                                        | notifier                                                                                                                                                                                          | the chain's admin                                                            | `DefaultChainUpgrade.setUpgradeTimestamp`                                                | per-chain operational decision — not upgrade composition                                   |
| A.3 | chain upgrade (`CTMUpgradeExecutor.upgradeChain` / chain-side `upgradeChainFromVersion`) | executor / chain diamond                                                                                                                                                                          | owner, chain admin, or anyone after the deadline                             | `DefaultChainUpgrade`                                                                    | already on-chain                                                                           |
| A.4 | `test_upgrade_chain`, `test_create_chain`                                                | —                                                                                                                                                                                                 | —                                                                            | `prepareDefaultTestUpgradeCalls`                                                         | tooling (simulator checks)                                                                 |

### What stays in tooling

Compilation; CREATE2 deployment of implementations, releases, transitions, registries, executors
and the bootstrap migration; bytecode publication on `BytecodesSupplier`; object inspection and
manifest diffing; transaction submission and replay (`protocol-ops` `upgrade-governance`, PUVT);
per-chain calldata substitution (performed by the pinned upgrade engine at execution).

## 2. Outer orchestration (protocol-ops)

`run_upgrade_prepare_all` (`protocol-ops/src/commands/ecosystem/upgrade.rs`) runs the core prepare,
then each ZKsync OS CTM prepare in input order (Era CTMs are skipped), then — when `[new_gateway]`
is configured — `GatewayVotePreparation`. `write_merged_ecosystem_toml` then DECIDES:

- which core registry and which CTM transition belong to the same upgrade (whatever was prepared
  in this run);
- their execution order — core before CTM in every stage;
- what else rides stage 0 (PUH/Guardians redeploy calls; CTM `acceptOwnership` normalization);
- what else rides stage 2 (the new-Gateway bundle).

Moving the Solidity stage methods on-chain without this layer would leave participation and
ordering off-chain. The on-chain workflow must know which objects participate in an upgrade and
enforce the order itself (Section 4). The anvil harness today even runs the recurring leg in the
OTHER order (`applyCTMUpgrade` before `applyL1Upgrade`,
`registry-upgrade-test-runner.ts` step 6) — exactly the kind of drift a script-defined order
permits.

## 3. Remaining script-defined behaviour

| Component                       | What the script decides today                                                                                                                                                                                                                                      | Where it moves                                                                                                                                                                  |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Core + CTM upgrade composition  | which core registry and CTM transition belong together, their order, and the extra calls appended to each stage (`write_merged_ecosystem_toml`)                                                                                                                    | executor stage logic; the transition REFERENCES the participating `CoreRegistry`                                                                                                |
| Stage bodies                    | pause/unpause, timer start/check, proxy swaps, version commit + release pins, handovers, applied-state checks (`prepareStage{0,1,2}GovernanceCalls` + overrides)                                                                                                   | `CTMUpgradeExecutor.stage0/1/2(transition)`                                                                                                                                     |
| ServerNotifier upgrade          | proxy, new implementation, and a separate `ChainAdmin` transaction (`prepareDefaultCTMAdminCalls`)                                                                                                                                                                 | an explicit inventory row (`CTMContract.ServerNotifier`) plus an authorized execution path                                                                                      |
| L2 migration-call construction  | delegate deployment, delegate address, initialization arguments, complex-upgrader wrapper calldata (`CTMUpgrade_v34.getL2UpgradeCalldata`, `getAdditionalUniversalForceDeployments`, `getL2UpgradeTargetAndData`; the harness's `registry-manifest.ts` mirrors it) | transition composition + pinned version-specific composer code                                                                                                                  |
| Bootstrap chain-upgrade payload | the `ProposedUpgrade` / cut handed to the bootstrap engine (`DefaultCTMUpgrade.generateUpgradeData` → `CTMUpgradeBase.getProposedUpgrade`; mirrored in the harness's `bootstrap-upgrade-stage.ts::buildBootstrapCut`)                                              | bootstrap-specific on-chain composition from pinned inputs — NOT a second general path                                                                                          |
| Bootstrap authority setup       | which ownership transfers precede `migrate()` and in what order (`prepareVersionSpecificStage1GovernanceCallsL1`)                                                                                                                                                  | the unavoidable authorization calls stay explicit; their destinations are bound and validated by the bootstrap object (they already are: `validate()` requires both ownerships) |
| Gateway activation and wiring   | settlement-layer registration, CTM registration, notifier configuration, ownership acceptance (`GatewayGovernanceUtils`, `GatewayVotePreparation`)                                                                                                                 | **deferred** while Gateway is out of scope                                                                                                                                      |
| Governance-contract upgrade     | PUH/Guardians upgrade and wiring folded into stage 0 (`zk_governance.rs`)                                                                                                                                                                                          | **separate scope**, explicitly connected to the reviewed upgrade                                                                                                                |

Not counted as missing migrations: the base-script proxy helpers overridden by the v34 registry
executor; `prepareDAValidatorCall` (commented out); facet-cut derivation and normal proposal
composition (on-chain); per-chain calldata substitution (pinned engine); compile/deploy/publish/
inspect/submit; a chain admin's own `setUpgradeTimestamp`.

## 4. Target model

### 4.1 Objects gain only the inputs the stage code needs

Keep the release / transition / core-registry model. `TransitionManifest` gains:

- `coreRegistry` — the participating `CoreRegistry` (zero when the upgrade has no ecosystem
  leg). Content provenance is already enforced by the ecosystem executor's `CORE_REGISTRY_CODEHASH`
  pin; the transition names WHICH one participates, so participation is reviewed with the
  transition and enforced on-chain.
- `upgradeTimer` — the pinned `GovernanceUpgradeTimer` for this upgrade (the shape the bootstrap
  manifest already has). Behaviour-preserving: stage 0 starts it, stage 1 requires its deadline,
  and the ecosystem admin keeps the bounded extension right through the timer's own `owner`. The
  timer is deployed with `TIMER_GOVERNANCE = CTMUpgradeExecutor`, and the executor checks that
  binding at stage 0 (a timer nobody else can start).

Targets come from the executor's bound contracts (`CHAIN_TYPE_MANAGER`, `CTM_PROXY_ADMIN`, and a
bound `ECOSYSTEM_EXECUTOR`) or authoritative getters (`BRIDGE_HUB.chainAssetHandler()`), never from
caller-supplied calldata. No `Call[]` enters a stage. Every executable version-specific piece
(upgrade engine, L2 composer, delegate) is codehash-pinned.

### 4.2 The three entrypoints on `CTMUpgradeExecutor`

Stored state: `pendingTransition`, `stage` (`None → Prepared → Executed → Completed`), and the
pause bookkeeping of 4.3.

| Entrypoint           | Behaviour migrated                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `stage0(transition)` | `onlyOwner`. Reject if another transition is mid-lifecycle. Genuine-object check, `validate()`, both edges (release + version), the named `coreRegistry`'s pin, this executor's authorization on the ecosystem executor, and the timer's binding — so a wrong object or a missing bootstrap join fails BEFORE anything is recorded. Record `pendingTransition`. Take this executor's hold on the migration pause (4.3). `timer.startTimer()`.                  |
| `stage1(transition)` | `onlyOwner`. Same transition, stage `Prepared`. `timer.checkDeadline()`. Migrations must be paused. Ecosystem leg FIRST (`ECOSYSTEM_EXECUTOR.applyL1Upgrade(coreRegistry)` when referenced — the order the merged bundle has today). Then the existing `applyCTMUpgrade` body, made internal: publication check, CTM-domain rows (incl. the notifier row, 4.4), `setNewVersionUpgradeFromTransition`, `setCurrentRelease`. Any revert reverts the whole stage. |
| `stage2(transition)` | `onlyOwner`. Same transition, stage `Executed`. Completion checks: `validateTransitionApplied` (committed edge, version, CTM-domain rows) and `ECOSYSTEM_EXECUTOR.validateUpgradeApplied(coreRegistry)` when referenced. Then restoration: release THIS upgrade's migration pause (4.3). Mark `Completed`, clear the pending slot.                                                                                                                             |

Rejected explicitly: a different transition at stage 1 or 2, a skipped stage, a duplicate stage, an
unauthorized caller. `applyCTMUpgrade` disappears as a public entrypoint so the lifecycle cannot
be bypassed. Stage 2 keeps today's meaning — completion checks plus restoration; it is NOT
redefined as "every chain has finalized its L2 upgrade" (a separate policy decision).

### 4.3 Migration pause: narrow route, shared flag

`pauseMigration`/`unpauseMigration` are `onlyOwner` on the shared `L1ChainAssetHandler`, whose
owner is governance. The stages need a route that (a) does not hand a CTM executor unrestricted
ecosystem authority, (b) cannot let one upgrade's stage 2 clear a pause another upgrade still
needs, and (c) preserves a pre-existing governance pause.

Implemented: the ChainAssetHandler has an owner-managed allowlist of UPGRADE PAUSERS
(`setUpgradePauser`) and per-pauser holds (`acquireMigrationPause` / `releaseMigrationPause`).
`migrationPaused()` is `ownerPaused || upgradePauseHolds != 0`; a pauser can only acquire and
release ITS OWN hold, releasing is gated on the hold rather than the allowlist (a de-registered
executor can still let go), and the owner has `clearMigrationPauseHold(pauser)` for a stuck one.
The owner's own `pauseMigration` / `unpauseMigration` touch only the owner's flag. A CTM executor
is registered once — an explicit governance call the v34 CTM prepare emits in its stage 2, bound
to the bootstrap's pinned executor. Overlapping upgrades and a pre-existing pause then compose
without any executor-side bookkeeping.

### 4.4 ServerNotifier: an explicit row and an authorized path

The notifier is a per-CTM proxy but sits under its OWN `ProxyAdmin`, owned by the CTM's
`ChainAdmin` — not under `CTM_PROXY_ADMIN`. Implemented: `ProxyUpgradeRow.admin` names the
`ProxyAdmin` administering the row's proxy (zero = the executor's bound admin), reads go through
it (a transparent proxy answers `implementation()` only to its own admin, so the bound admin
cannot even inspect the notifier), and the row applies only if the executor OWNS the named admin —
otherwise stage 1 leaves it to that administrator (`ProxyRowLeftToAdministrator`) and stage 2
requires it applied. `CTMContract.ServerNotifier` is the row's slot; the v34 bootstrap manifest
carries the notifier swap under its chainAdmin-owned admin, `migrate()` leaves it to the
ChainAdmin's own `ctm_admin_calls` (which protocol-ops runs right after the prepares), and
`validateApplied()` requires it. Both authority policies are therefore expressible as on-chain
state: hand the notifier's admin to the executor and the row rides stage 1; keep it with the
ChainAdmin and the ChainAdmin's own call must land before stage 2. `validate()` on the bootstrap
accepts a row already at `implNew` for exactly this reason.

### 4.5 Bootstrap stays one-shot; the lifecycle starts at the first transition

`RegistryBootstrapMigration` remains the entry edge and is reused as is. The recurring lifecycle
applies from the first registry-driven transition after it (v34 → v35). Join conditions: after
`migrate()` the executor owns the CTM and its ProxyAdmin; the ecosystem `ProxyAdmin` is handed to
the ecosystem executor (today's 1.2); the CTM executor is registered as an upgrade pauser and, if
4.4's first alternative is chosen, owns the notifier's ProxyAdmin. Each is one explicit
authorization call bound to bootstrap data; none is required by a stage before it exists.

The bootstrap's remaining script-composed payload (the `ProposedUpgrade` inside `upgradeCut`) moves
into the bootstrap object: the manifest pins the L2 plan and the engine, and the cut is composed on
read from those pinned inputs with the same composer the transitions use — bootstrap-specific
inputs, shared composition code, no second permanent path.

### 4.6 L2 migration composition

The manifest stops carrying `delegateTo` and `delegateCalldata`. It pins the delegate's bytecode
info (which DETERMINES its unsafe-deployment address) and a version-specific L1 composer
implementing a fixed interface, pinned by codehash; at composition time the composer produces the
delegate calldata from authoritative inputs (the target release's `fixedForceDeploymentsData`,
the CTM's Bridgehub for `ctmDeploymentTracker`) — so the arguments are defined by audited code,
not authored bytes. `L2PlanValidationLib`'s invariants (extras unsafe and bytecode-derived,
delegate ∈ extras, every installed bytecode in the factory deps, publication at commit) stay.

### 4.7 Tooling after the migration

Prepare scripts deploy objects and emit exactly:
`CTMUpgradeExecutor.stage0(t)`, `stage1(t)`, `stage2(t)`. Any remaining external action —
the bootstrap authorization calls, the governance self-upgrade, Gateway bring-up — is listed
explicitly in the output; the tooling must never imply the three calls cover it when they do not.
The Rust merger stops concatenating stage bodies.

## 5. Proof obligations

Replay the scripted flow and the on-chain flow against equivalent fixtures (the anvil
`v33 → v34 → v35` pipeline and `UpgradeTestv34_Local`) and compare: CTM storage
(`protocolVersion`, `currentRelease`, `releaseCodehash`, `upgradeTransition[old]`,
`protocolVersionDeadline`), every inventory row's live implementation, ownership of the CTM and
both ProxyAdmins, `migrationPaused` before/between/after stages, emitted events, and the composed
chain payload (`upgradeCutForVersion`) byte for byte.

Targeted tests:

- wrong transition at stage 1/2, skipped stage, duplicate stage, unauthorized caller;
- a failure partway through stage 1 (e.g. a row at an unexpected implementation) reverting the
  whole stage — no partial commit;
- cross-executor authority: the CTM executor can drive the ecosystem leg only for the registry its
  pending transition names; a stranger cannot;
- overlapping upgrades and a pre-existing governance pause: stage 2 of one upgrade leaves the
  other's hold and the owner's flag in place;
- completion checks failing BEFORE restoration (no unpause when the applied-state check fails);
- bootstrap followed by a normal registry-driven upgrade (the pipeline's shape).

## 6. Order of work

1. This inventory (baseline) — done.
2. Object inputs: `coreRegistry` + `upgradeTimer` on the transition — done; CAH pauser holds —
   done; notifier row with its explicit admin — done (4.4).
3. `stage0/1/2` on `CTMUpgradeExecutor`; `applyCTMUpgrade` internal — done.
4. Authority: ecosystem executor's narrow CTM-executor authorization and pauser registration —
   done (both emitted by the v34 CTM prepare's stage 2 as explicit bootstrap-join calls); notifier
   ProxyAdmin path — done (the row names its admin; the executor applies it only if it owns it).
5. Bootstrap join: explicit bound authorization calls; no bootstrap machinery on transitions.
6. Tooling: scripts emit the three calls; the Rust merger stops composing stage bodies; every
   remaining external action listed.
7. Equivalence replay + targeted tests (Section 5).
8. Only then: simplify the no-Gateway path behind the same stage interface.

## Executor succession

The CTM executor stores its ecosystem executor explicitly because that relationship cannot be
recovered from a transparent proxy by an arbitrary caller. This is a replaceable binding, not
an immutable dependency: `setEcosystemExecutor` is owner-only, requires no pending transition,
and requires the successor to name the same ecosystem ProxyAdmin. Governance transfers that
ProxyAdmin through the old executor's owner-gated `forward`, authorizes the existing CTM executor
on the successor, and updates the binding. A single governance transaction can perform the whole
handover. Stage 0 still checks authorization before taking a pause hold.

This changes neither the CTM executor's bound CTM nor its transition provenance anchor. Replacing
an object schema or its accepted codehash is a separate migration and must not be simulated by
silently regenerating already-deployed source state.
