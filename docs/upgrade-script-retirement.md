# Deployment and upgrade script retirement plan

> **Temporary plan — delete after implementation.** Once all retirement batches are complete
> and their verification gates pass, move any lasting architectural decisions into the canonical
> documentation, delete this file, and remove links to it from the architecture document and PR
> description. Do not retain it as a permanent description of the implemented system.

Companion to [the registry architecture](registry-driven-upgrades.md). This is an implementation
plan for PR #2270, not a claim that the proposed inventory and deployment changes are implemented.
The objective is to delete script-defined protocol behavior while retaining a small artifact and
transaction client. Every batch must name the code it removes and the checks that replace it.

## Target boundary

The off-chain client accepts the operator's explicit proposed changes, compiles and deploys code,
publishes bytecode, creates the existing registry objects, reads their description, simulates the
operation and submits transactions. Selecting a desired change remains an operator decision.
Resolving its consequences, constructing executable upgrade payloads, ordering protocol actions,
and enforcing the resulting state belong in audited on-chain code.

Do not replace Solidity scripts with equivalent Rust or TypeScript orchestration. Do not move an
unrestricted `Call[]` interpreter on-chain and call the migration complete. Reuse releases,
transitions, core registries, executors and existing deployment primitives wherever possible;
introduce another permanent contract type only if a concrete responsibility cannot fit them.

## Baseline and work already in progress

Committed behavior includes the executor lifecycle, pause holds, explicit ProxyAdmin rows,
on-chain L2 and bootstrap composition, declared external actions, individual-contract execution
tests and lifecycle recovery. The bootstrap already removes selectors from the departing diamond's
live routing storage and installs the pinned release; no legacy selector discovery feature is needed.

At the time of this plan, uncommitted work includes removal of the duplicate composer,
`DefaultL2UpgradeStrategy`, modern chain-call cleanup and deployment-member reuse. Review and
finish those edits as batch 1 rather than implementing parallel versions. They are not treated as
verified merely because they are present in the worktree. Other generated-file/build changes must
be kept separate from documentation and reviewed with their owning batch.

**Batch 1 is implemented** (see its section below for what landed and what it uncovered). Batches
2-5 are unimplemented plan.

## Batch 1: finish the deletion that current contracts already enable

**Status: implemented.** What landed, against the changes listed below:

- The v34 prepare READS `RegistryBootstrapMigration.upgradeCut()` and writes those bytes out; the
  script-side proposal, L2 transaction and delegate-calldata composition are gone, and with them
  `DefaultL2UpgradeStrategy` and most of `CTMUpgradeBase`.
- The equivalence evidence is field-level and independent, not two calls into one composer: the
  bootstrap unit suite builds the expected proposal and transaction from the manifest inputs
  (`RegistryBootstrapMigration.t.sol`), and the in-forge bootstrap integration test decodes the
  cut the prepare shipped and reads it back field by field against the committed hash, the pinned
  engine, the release's verifier and the all-zero L2 transaction.
- `AdminFunctions.upgradeChainFromCTM` selects the modern cut-READING entrypoint FIRST
  (`UpgradeChainCall.requiresCut`) and reconstructs a cut from the CTM's historical log only for a
  pre-bootstrap chain. `DefaultChainUpgrade.executeUpgrade` is deleted: the chain diamond's
  `executeUpgrade` is `onlyChainTypeManager`, so it could not succeed. `DefaultChainUpgrade` held a
  second copy of the same selection in its own `run`; that copy was removed in batch 2 once it was
  established that nothing called it.
- The upgrade output's `diamond_cut_data` is retired after tracing its consumers; the field is now
  optional in the verifier (shipped v31-v33 artifacts still carry it) and its cross-check is
  skipped when absent. `force_deployments_data` and `chain_upgrade_diamond_cut` stay: both have
  live functional consumers (new-Gateway bring-up; the anvil bootstrap chain leg).
- Unchanged release members are reused by CODE IDENTITY: the prepare probes what the current
  sources produce (a local, never-broadcast deployment with this run's constructor arguments — an
  artifact's `deployedBytecode` has immutable slots zeroed and cannot be compared with live code)
  and keeps the live member when they match. A release whose members all reused pins an identical
  manifest, so the live release object is reused too and the transition derives an empty L1 delta.
- Replacing a live member is a change of SCOPE and must be INTENDED: the prepare refuses to
  replace any member the version does not name in `changedReleaseMembers()`. A version that
  changes one ecosystem contract therefore cannot quietly become one that replaces the facet set
  because the local build disagrees with whatever produced the live code. The v34 bootstrap
  declares the whole set, since it authors a complete release for a pre-registry ecosystem.
- `DiamondInit` gets its address from the CTM's current RELEASE. It is the genesis cut's init
  target rather than a routed facet, so a chain's routing cannot expose it and introspection left
  it zero — which made every upgrade deploy a fresh one and move the release even when nothing
  about the release changed. Found by the pipeline's reuse assertion, not by reading the code.
- Two findings this batch turned up, fixed here because both brick a lifecycle in production:
  a codehash pin taken from a build artifact while the object is deployed from the script's own
  compiled copy can differ (the CBOR metadata records the compilation's remappings), so pinned
  registry objects are now deployed from the same artifact the pin is read from
  ({BytecodeUtils}: `readBytecodeL1` to deploy, `getDeployedBytecodeHash` to pin) and the CTM
  prepare re-checks every object it deploys against the live
  executors' immutables; and reading build artifacts inside the pipeline's own call frame charges
  memory quadratically, so the member probe runs in its own frame.

### Changes

- Read the bootstrap cut from `RegistryBootstrapMigration.upgradeCut()` and recurring payloads
  from the transition/CTM composer. Remove independent proposal, transaction and delegate-calldata
  construction from prepare scripts.
- Move historical composition-equivalence evidence into tests or frozen expected payloads.
  Comparing two calls into the same composer is not an independent regression check.
- Select the modern chain entrypoint before loading any cut. Only supported pre-bootstrap chains
  need a cut-taking ABI; that adapter reads and forwards the on-chain-composed bootstrap payload.
- Remove legacy genesis/cut output fields after tracing every Rust, test and deployment consumer.
  A temporary compatibility serializer must read the authoritative object, not reconstruct it.
- Finish unchanged-member reuse without silently upgrading another member because local build
  artifacts differ. Artifact differences should be surfaced to the operator, not expand scope.

### Delete or shrink

`DefaultL2UpgradeStrategy.sol`; composition methods in `CTMUpgradeBase.sol`; v34's duplicate
`getL2UpgradeCalldata` and cut-comparison path; legacy branches in `DefaultChainUpgrade` and
`AdminFunctions`; obsolete fields in upgrade parameters and output TOML. Keep small version-specific
L2 input hooks until their consumers are replaced. Remove an empty base class rather than preserving
its inheritance name.

### Gate

Run the frozen bootstrap and recurring-prepare pipelines. Assert the committed payload, final
routing, freezability, verifier and relevant storage/events. Cover legacy facets without
self-description, multiple/custom facets, a lagging chain after the CTM advances, and atomic rollback
on failure. Modern preparation must work without historical log access. Small-change tests must
check both installed state and the deployment list: unchanged members must not be redeployed.

## Batch 2: move the remaining script-defined actions into the existing flow

**Partially implemented.** The deletions whose responsibilities already had a replacement have
landed; the address-discovery and gap-closing work below is still plan.

What landed, each verified by naming the surviving owner of the responsibility rather than by
absence of a caller:

- `deploy-scripts/gateway/GatewayPreparation.sol` (690 lines, 18 entrypoints) is deleted. Nothing
  imported it — the gateway flow runs through `_GatewayPreparationForTests.sol`, which extends
  `GatewayGovernanceUtils` — and every function it declared has a live equivalent in
  `AdminFunctions.s.sol` or `GatewayUtils.s.sol`.
- `ICoreUpgradeV31.stage3` and its `protocol-ops ecosystem stage3` plumbing are deleted. The
  command resolved to `deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol`, which no longer exists,
  so it could not succeed; a sweep of every forge-script path the Rust table declares found this
  to be the only unresolvable one. Its responsibility is discharged rather than moved: as
  {protocol-docs/bridging.md} records, every ecosystem the current release can upgrade has already
  been populated, and the driver tooling belongs on that release's branch. The four
  `*-bridged-tokens.toml` fixtures go with it — their reader, `TokenMigrationUtils.s.sol`, is
  already gone.
- `deploy-scripts/provider/` (864 lines: a Solidity JSON-RPC client plus the eight FFI bash
  scripts it shelled out to) is deleted. Nothing referenced it and nothing documented it; reading
  receipts, logs and proofs from a node is done by the TypeScript and Rust tooling, which is also
  where the repo has been moving shell invocations OUT of scripts.
- `DefaultChainUpgrade.run`, `upgradeChainWithoutCut`, `setUpgradeTimestamp` and `getChainConfig`
  are deleted (114 lines to 69). The first two duplicated the cut selection that
  `AdminFunctions.upgradeChainFromCTM` owns; `setUpgradeTimestamp` duplicated
  `AdminFunctions.adminScheduleUpgrade`, which is what `protocol-ops chain set-upgrade-timestamp`
  actually drives. What remains is the legacy handed-cut path the Foundry integration tests use.

- Eight dead members on the upgrade bases and the introspector: `getGatewayConfig`,
  `getGovernanceUpgradeTimerInitialDelay` and `getTestnetVerifier` on `DefaultCTMUpgrade`,
  `setOwners` and `getCoreAddresses` on `DefaultCoreUpgrade`, `getAllForChain` and its sole
  callee `getZkChainFacetAddresses` on `AddressIntrospector`, and both copies of the empty
  `saveOutputVersionSpecific` extension point (wired but never overridden by any version). The
  one-field `GatewayConfig` struct and its never-written storage variable go with their getter.
  None is declared in a script-interface, so none is part of the `zkstack` API surface.
  `DeployCTM.run()` stays — nothing calls it, but `IDeployCTM` declares it — with its comment
  corrected: it claimed to exist for inheriting scripts and tests, and neither is true.

Three scripts with no in-repo caller were deliberately KEPT, because "no caller" is the wrong
test for a hand-run entrypoint: `DeployPrividiumTransactionFilterer.s.sol` is the only deployment
path for a live product contract, `tokens/DeployZKAndBridgeToL1.s.sol` is the ZK-token bring-up,
and `utils/BlakeContractHashing.s.sol` answers a single ad-hoc hash that full regeneration does not.
Each is an operator or developer command; none has a replacement.

A boundary this batch established, which constrains what else may be deleted: every file in
`contracts/script-interfaces/` is exported to `l1-contracts/zkstack-out/` and consumed by the
external `zkstack` CLI. Absence of an in-repo caller is therefore NOT evidence that one of those
declarations is dead — removing one is a cross-repo API break. `stage3` qualified only because the
script behind it had already been deleted, which breaks it for every consumer equally.

No new permanent registries and no deployment-inventory redesign in this release. `CTMRelease`,
transitions, the existing `CoreRegistry` upgrade object and their current execution model stay as
they are; the `CoreRegistry` name does not imply a permanent registry architecture behind it. An
earlier draft of this batch specified exactly such a redesign — a `CTMRegistry` current-inventory
object, derivation from source and target snapshots, an applied-inventory pointer — and that is
withdrawn. What remains is narrower and does not add object types.

### Changes

- Move script-defined upgrade ACTIONS into the on-chain flow that already exists. The measure is
  the acceptance criterion below: an action a prepare script decides is a candidate; an action an
  existing object already describes is not.
- Discover addresses through EXISTING getters rather than reconstructing them. `DiamondInit` is
  the worked example already landed in batch 1: it is the genesis cut's init target rather than a
  routed facet, so no chain routing exposes it, introspection reported zero, and every upgrade
  silently deployed a fresh one — until it was read from the CTM's own `currentRelease`. The same
  question is worth asking of every address a prepare still reconstructs.
- Remove a script only where its responsibility ALREADY has a replacement. A deletion whose
  replacement is "the operator will remember" is not a deletion.
- Close the security and execution gaps in the design as it stands, rather than deferring them to
  a redesign. The bootstrap owner-binding fix is the pattern: a small, separate correction with
  its own tests, landed without waiting for anything larger.

### Delete or shrink

Only what has a replacement. Address reconstruction in `setAddressesBasedOnCTM` and
`setAddressesBasedOnBridgehub` shrinks exactly as far as existing getters reach, and no further;
discovery stays for the legacy bootstrap and for reports, with explicit legacy boundaries.

### Gate

Exercise facet-only, verifier-only, timelock-only, notifier-only, core-only and mixed upgrades
through the CURRENT objects. Test stale source state, wrong admin, codehash mismatch and
foreign-admin completion. Every address a prepare no longer reconstructs must be shown to come
from a getter that the deployed contracts actually expose.

## Batch 3: move cross-contract follow-up work into audited execution

### Changes

Inventory all declared external actions and classify each by reason: bootstrap authorization,
foreign administrator, upgrade-specific wiring, governance self-upgrade, or Gateway operations.
Use concrete existing calls to establish the required scope.

For wiring intrinsic to an upgrade, prefer an existing implementation's fixed initializer when it
has the required authority and can express the complete action. Otherwise define a narrowly scoped,
pinned execution hook within the existing upgrade architecture. Decide call versus delegatecall,
target binding and privilege explicitly before implementation. The hook must not depend on
operator-authored arbitrary calldata to decide its effects.

Specify before/after ordering, replay behavior and postconditions for each action. Keep work that
must be atomic inside one transaction. If execution spans different authorities, the lifecycle must
expose the pending requirement and verify it before normal completion.

### Delete or shrink

Version-specific `prepareVersionSpecificStage*GovernanceCalls*` bodies that construct protocol
wiring; duplicated per-target validation calls; Rust appends for actions now enforced by the
executor. Retain explicit declarations for independently authorized work until its authority is
actually integrated. An allowlisted description does not grant execution rights.

### Gate

Test a representative multi-contract upgrade with real authorization. A failed follow-up must
revert the atomic leg; skipped or incorrectly applied work must prevent normal completion. Test
unauthorized targets, replay, a foreign-admin row and owner abandonment after stage 1. Abandonment
must preserve its documented non-rollback semantics.

## Batch 4: establish deployment wiring and authority on-chain

### Changes

Fresh ecosystem/CTM setup should finish in a state ready for an ordinary registry transition.
Map the calls currently performed by `DeployL1CoreContracts` and `DeployCTM`: dependency wiring,
CTM/notifier association, ownership transfers, pending-admin acceptance, executor ownership and
pause/ecosystem authorization.

Use existing initialization/deployment primitives where they can provide atomic deployment and
setup. If a finalization operation is needed, bind it to the intended contracts and intended
owners, and make it one-shot. Do not add a generally privileged deployment orchestrator. For existing
contracts, retain the required approval from their current owner; an on-chain helper cannot invent it.

Address circular constructor dependencies through deterministic deployment or supported atomic
initialization. Keep L1 and L2 constraints separate: L2 contracts cannot acquire constructor/immutable
requirements through shared bases. Do not put the no-Gateway path behind Gateway deployment.

### Delete or shrink

Protocol wiring in `setBridgehubParams`, vault/router/nullifier setters,
`setChainTypeManagerInServerNotifier`, and `updateOwners`; script-side sequencing and repeated
ownership checks superseded by finalization. Keep artifact deployment and transaction submission.

### Gate

Deploy a fresh ecosystem and CTM, verify all dependency and authority relationships, then execute
an individual-contract transition without legacy bootstrap preparation. Test partial setup,
unauthorized/repeated finalization, incorrect bindings, failed handover and absence of an exposed
initialization window. Verify that required signatures remain required for existing deployments.

## Batch 5: collapse production preparation and isolate bootstrap

### Changes

After batches 2–4, use one reusable prepare client for the existing registry objects. Inputs are
explicit changed members, new artifact references, schedule and any pinned version-specific code.
Read unchanged members and derived payloads from the authoritative objects. A new version should
need custom code only for new protocol behavior, not another version-specific prepare hierarchy.

The recurring output should identify source/target objects, implementation/codehash changes,
required authorities, stage transactions and unresolved external actions. Reporting may format
on-chain facts; it must not independently decide execution order or recreate the payload.

Keep the pre-registry entry edge in a small named legacy adapter. Do not delete its cut-taking ABI,
handovers or frozen tests while supported chains still require them. Retire the adapter only after
checking the supported deployment/version inventory and upgrade deadlines.

### Delete or shrink

The `DefaultCTMUpgrade` / `DefaultCoreUpgrade` inheritance layers, empty version subclasses,
`CTMUpgradeBase` once its remaining hooks move, `UpgradeHelperLib` and stage-merging helpers with
no consumers. Remove obsolete `UpgradeStageValidator` deployment when its remaining bootstrap
postcondition is enforced elsewhere. Keep generic Safe serialization, signer handling and simulation.

### Gate

Production preparation must demonstrate bootstrap, recurring no-Gateway, individual-member,
L1-only and mixed L1/L2 flows. Assert that every submitted call is an executor operation or an
explicitly required external action. A report with no unresolved actions must correspond to an
operation the specified authorities can actually execute.

## Delivery order and review discipline

Batch 1 can land independently, and has landed. Batches 2, 3 and 4 each move a class of
script-defined action into the flow that already exists, in any order that keeps a deletion next
to its replacement. Batch 5 removes the remaining scaffolding once those replacements exist.
Split each batch further where needed to keep the deletion and its replacement reviewable.

For every implementation commit:

1. List each removed script responsibility, its former callers and its new authoritative location.
2. Add outcome-based regression tests before removing the reference path. Preserve old fixtures.
3. Run the relevant unit/integration tests and production-path replay; compare actual state,
   authorities, payloads and deployment lists rather than only successful receipts.
4. Refresh ABIs, selectors, hashes and current-source fixtures when affected. Do not mix unrelated
   worktree edits into the batch. Keep generated changes separate enough to review.
5. Update the architecture document and PR description. Describe remaining external work explicitly.

Completion means an upgrade can be understood and executed from its on-chain objects plus the
identified approvals. Scripts contain no independent selector lists, payload composition,
protocol-wiring decisions or stage semantics. Human review
of new implementation code, configuration choices and governance approvals remains necessary.
