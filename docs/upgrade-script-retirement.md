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
- `AdminFunctions.upgradeChainFromCTM` and `DefaultChainUpgrade.run` select the modern
  cut-READING entrypoint FIRST (`UpgradeChainCall.requiresCut`) and reconstruct a cut from the
  CTM's historical log only for a pre-bootstrap chain. `DefaultChainUpgrade.executeUpgrade` is
  deleted: the chain diamond's `executeUpgrade` is `onlyChainTypeManager`, so it could not succeed.
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
  ({PinnedRegistryObject}) and the CTM prepare re-checks every object it deploys against the live
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

## Batch 2: make the deployment inventory authoritative

### Design and changes

The current release describes chain code; upgrade rows describe operations. An inert row means
"do not upgrade", not "this is the currently deployed contract". Resolve that distinction before
removing address-book reconstruction.

- Define a complete current inventory for each CTM and the shared ecosystem, extending the existing
  object model rather than defaulting to another registry type. Record direct deployment addresses
  and codehashes; distinguish proxy address, implementation, implementation pin and ProxyAdmin.
- Decide which upgrade-relevant configuration is authoritative inventory data and which remains
  mutable operational state. Do not mirror all contract storage.
- Give callers a discoverable current inventory pointer through the CTM/executors. Preserve the
  distinction between a proposed target, a committed transition and a fully applied inventory.
- Derive executable proxy rows from source and target inventories: reuse unchanged members, reject
  unsupported target/admin changes, and bind each change to its expected live source state.
- Define how the pointer advances when a foreign administrator owns a row. A pending target must
  not be represented as fully applied before completion checks pass.
- Define shared-ecosystem behavior across multiple CTMs. A CTM completion must not overwrite a newer
  ecosystem pointer or claim that another CTM's chain upgrade has completed.
- Define reconciliation after owner recovery calls alter live state. Pins and pointers describe
  intended state; they are not proof that a proxy still matches it.

### Delete or shrink

Upgrade-specific reconstruction in `setAddressesBasedOnCTM`, `setAddressesBasedOnBridgehub`,
`_ctmProxyUpgradeRows` and `_coreProxyUpgradeRows`; duplicate current-address TOML used as an
execution input; repeated discovery of unchanged release members. Retain discovery for legacy
bootstrap and reports, with explicit legacy boundaries.

### Gate

Exercise facet-only, verifier-only, timelock-only, notifier-only, core-only and mixed upgrades.
Test stale source state, wrong admin, codehash mismatch, foreign-admin completion, concurrent/shared
core upgrades and recovery-induced drift. Demonstrate the operator workflow: read current inventory,
change one member, create the transition, execute, verify the resulting current inventory.

Schema/codehash compatibility is a decision gate for this batch. Determine whether older objects
are deployed and define their migration if needed. Current-source fixture regeneration is not a
substitute. Existing committed transitions and lagging chains must retain access to their old objects.

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
setup. If a finalization operation is needed, bind it to the intended inventory and intended owners,
and make it one-shot. Do not add a generally privileged deployment orchestrator. For existing
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

Batch 1 can land independently. Batch 2 establishes the inventory model; batches 3 and 4 use that
model to bind execution and setup. Batch 5 removes the remaining scaffolding after those replacements
exist. Split each batch further where needed to keep the deletion and its replacement reviewable.

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
protocol-wiring decisions, stage semantics or competing current-deployment inventory. Human review
of new implementation code, configuration choices and governance approvals remains necessary.
