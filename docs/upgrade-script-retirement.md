# Deployment and upgrade script retirement plan

> **Temporary plan — delete after implementation.** Once all retirement batches are complete
> and their verification gates pass, move any lasting architectural decisions into
> [the architecture document](registry-driven-upgrades.md), delete this file, and remove links to
> it. Do not retain it as a permanent description of the implemented system.

This is an implementation plan for PR #2270, not a description of the implemented system. The
objective is to delete script-defined protocol behavior while retaining a small artifact and
transaction client. Every batch must name the code it removes and the checks that replace it.

## Target boundary

The off-chain client accepts the operator's explicit proposed changes, compiles and deploys code,
publishes bytecode, creates the existing registry objects, reads their description, simulates the
operation and submits transactions. Selecting a desired change remains an operator decision.
Resolving its consequences, constructing executable upgrade payloads, ordering protocol actions,
and enforcing the resulting state belong in audited on-chain code.

Do not replace Solidity scripts with equivalent Rust or TypeScript orchestration. Do not move an
unrestricted `Call[]` interpreter on-chain and call the migration complete. Reuse releases,
transitions, core registries, operations, executors and existing deployment primitives wherever
possible; introduce another permanent contract type only if a concrete responsibility cannot fit
them. A boundary batch 2 established: every file in `contracts/script-interfaces/` is exported to
`l1-contracts/zkstack-out/` and consumed by the external `zkstack` CLI, so absence of an in-repo
caller is NOT evidence that one of those declarations is dead.

## Status

Finished, and described where it now lives:

- **The stage machine is on-chain.** The scripted stage-0/1/2 bundles became
  `EcosystemUpgradeExecutor.stage0/1/2(operation)` over a write-once
  `EcosystemUpgradeOperation`; the domain executors (`CoreUpgradeExecutor`, `CTMUpgradeExecutor`)
  only answer the coordinator's callbacks. The three calls are derived from the operation; the Rust merger
  copies bundles and composes nothing. Spec: `protocol-docs/ecosystem-upgrade-coordination.md`.
- **`UpgradeStageValidator` is retired from the v34 path.** Its checks are absorbed: `migrate()`
  checks the timer's deadline, the CTM's version-edge commit refuses to run unpaused, and
  `validateApplied()` refuses while the CTM's migrations are still paused. The contract remains
  only because the v31 verifier reads its deployment.
- **The ServerNotifier admin call is rendered from the reviewed row**, not defined a second time in
  the script (`prepareUpgradeServerNotifierCall`; `ServerNotifierRowCall.t.sol`).
- **`ProposedUpgrade` is gone.** The engines read the transition (`upgradeFromTransition`) or the
  migration (`upgradeFromBootstrap`); nothing is repackaged into an intermediate struct.
- **`CTMUpgradeBase` and `DefaultL2UpgradeStrategy` are gone**; the L2 side a version authors is
  one `authorL2Side` result.
- **Proposal-local L1 codehash pins are removed.** Every proposal member is a plain address:
  `PinnedContract`, `CodehashPinLib`, the `_pins` enumerations and the non-reverting `verifyAll()`
  twin are gone, `validate()` now enforces that every named contract is deployed code, and
  `ObjectAnchorLib` keeps the two checks that remain. The four object-type ANCHORS still constrain
  later inputs, and the bootstrap establishes the CTM's from the live runtime code of the release
  governance approved. Described in
  [registry-driven-upgrades.md](registry-driven-upgrades.md#provenance-and-validation).
- Batch 1 (below) is implemented; batch 2 is partially implemented.

## Batch 1: finish the deletion that current contracts already enable — implemented

- The committed cut is READ from the object that composes it — `RegistryBootstrapMigration.upgradeCut()`
  for the bootstrap edge, the transition's composer for a recurring one. The script-side proposal,
  L2 transaction and delegate-calldata composition are gone.
- The equivalence evidence is field-level and independent: the bootstrap unit suite builds the
  expected proposal and transaction from the manifest inputs (`RegistryBootstrapMigration.t.sol`),
  and `UpgradeTestv34_Local` decodes the cut the prepare shipped and reads it back field by field.
- `AdminFunctions.upgradeChainFromCTM` selects the cut-reading entrypoint first
  (`UpgradeChainCall.requiresCut`) and reconstructs a cut only for a pre-bootstrap chain.
  `DefaultChainUpgrade.executeUpgrade` is deleted (the chain's `executeUpgrade` is
  `onlyChainTypeManager`, so it could not succeed).
- The output's `diamond_cut_data` is retired; the field is optional in the v31 verifier (shipped
  v31–v33 artifacts carry it). `force_deployments_data` and `chain_upgrade_diamond_cut` stay: both
  have live consumers (new-Gateway bring-up; the anvil bootstrap chain leg).
- Unchanged release members are reused by CODE IDENTITY: the prepare probes what the current
  sources produce (a local, never-broadcast deployment with this run's constructor arguments — an
  artifact's `deployedBytecode` has immutable slots zeroed) and keeps the live member when they
  match. A release whose members all reused is reused itself and the transition derives an empty
  L1 delta (`ReleaseMemberReuse.t.sol`).
- Replacing a live member is a change of SCOPE and must be INTENDED: the prepare refuses to replace
  any member the version does not name in `changedReleaseMembers()`. The v34 bootstrap declares
  the whole set, since it authors a complete release for a pre-registry ecosystem.
- `DiamondInit` comes from the CTM's current RELEASE. It is the genesis cut's init target rather
  than a routed facet, so introspection reported zero and every upgrade deployed a fresh one —
  found by the pipeline's reuse assertion.
- Two findings fixed here: a hash taken from a build artifact while the object is deployed from
  the script's own compiled copy can differ (CBOR metadata records the remappings), so registry
  objects are deployed from the same artifact a reviewer reproduces
  (`BytecodeUtils.readBytecodeL1`); and reading artifacts inside the pipeline's own call frame
  charges memory quadratically, so the member probe runs in its own frame.

## Batch 2: move the remaining script-defined actions into the existing flow — partial

Landed, each verified by naming the surviving owner of the responsibility:

- `deploy-scripts/gateway/GatewayPreparation.sol` (690 lines, 18 entrypoints) is deleted; the
  gateway flow runs through `_GatewayPreparationForTests.sol` → `GatewayGovernanceUtils`, and
  every function it declared has a live equivalent in `AdminFunctions.s.sol` or `GatewayUtils.s.sol`.
- `ICoreUpgradePrepare.stage3` and `protocol-ops ecosystem stage3` are deleted: the script behind
  them no longer existed, and {protocol-docs/bridging.md} records that every ecosystem the current
  release can upgrade is already populated. The four `*-bridged-tokens.toml` fixtures go with it.
- `deploy-scripts/provider/` (a Solidity JSON-RPC client plus eight FFI bash scripts) is deleted;
  the TypeScript and Rust tooling read receipts, logs and proofs.
- `DefaultChainUpgrade.run`, `upgradeChainWithoutCut`, `setUpgradeTimestamp` and `getChainConfig`
  are deleted; they duplicated `AdminFunctions.upgradeChainFromCTM` and `adminScheduleUpgrade`.
- Eight dead members on the upgrade bases and the introspector, the one-field `GatewayConfig`
  struct and both copies of the empty `saveOutputVersionSpecific` extension point are deleted.
  `DeployCTM.run()` stays because `IDeployCTM` declares it.

Deliberately KEPT despite having no in-repo caller — each is a hand-run operator command with no
replacement: `DeployPrividiumTransactionFilterer.s.sol`, `tokens/DeployZKAndBridgeToL1.s.sol`,
`utils/BlakeContractHashing.s.sol`.

No new permanent registries and no deployment-inventory redesign in this release. An earlier
draft of this batch specified a `CTMRegistry` current-inventory object with derivation from
source and target snapshots; that is withdrawn.

### Remaining

- Move script-defined upgrade ACTIONS into the on-chain flow that already exists. An action a
  prepare script decides is a candidate; an action an existing object already describes is not.
- Discover addresses through EXISTING getters rather than reconstructing them (`DiamondInit` is
  the worked example). `setAddressesBasedOnCTM` and `setAddressesBasedOnBridgehub` shrink exactly
  as far as existing getters reach; discovery stays for the legacy bootstrap and for reports.
- Remove a script only where its responsibility ALREADY has a replacement. "The operator will
  remember" is not a replacement.

### Gate

Exercise facet-only, verifier-only, timelock-only, notifier-only, core-only and mixed upgrades
through the CURRENT objects. Test stale source state, wrong admin, codehash mismatch and
foreign-admin completion. Every address a prepare no longer reconstructs must be shown to come
from a getter the deployed contracts expose.

## Batch 3: move cross-contract follow-up work into audited execution

Inventory all declared external actions and classify each by reason: bootstrap authorization,
foreign administrator, upgrade-specific wiring, governance self-upgrade, or Gateway operations.

For wiring intrinsic to an upgrade, prefer an existing implementation's fixed initializer when it
has the required authority and can express the complete action. Otherwise define a narrowly scoped,
pinned execution hook within the existing upgrade architecture. Decide call versus delegatecall,
target binding and privilege explicitly before implementation. The hook must not depend on
operator-authored arbitrary calldata to decide its effects. Specify before/after ordering, replay
behavior and postconditions for each action; keep work that must be atomic inside one transaction.

Delete or shrink: version-specific bodies that construct protocol wiring; duplicated per-target
validation calls; Rust appends for actions now enforced by the executors. Retain explicit
declarations for independently authorized work until its authority is actually integrated — an
allowlisted description does not grant execution rights.

Gate: a representative multi-contract upgrade with real authorization. A failed follow-up must
revert the atomic leg; skipped or incorrectly applied work must prevent normal completion. Test
unauthorized targets, replay, a foreign-admin row and abandonment after stage 1.

## Batch 4: establish deployment wiring and authority on-chain

Fresh ecosystem/CTM setup should finish in a state ready for an ordinary registry operation: the
domain executors deployed and owning their `ProxyAdmin`s / CTM, bound to a coordinator. Map the
calls `DeployL1CoreContracts` and `DeployCTM` perform today: dependency wiring, CTM/notifier
association, ownership transfers, pending-admin acceptance, executor ownership.

Use existing initialization/deployment primitives where they provide atomic deployment and setup.
If a finalization operation is needed, bind it to the intended contracts and owners and make it
one-shot. Do not add a generally privileged deployment orchestrator; for existing contracts,
retain the required approval from their current owner. Keep L1 and L2 constraints separate (L2
contracts cannot acquire constructor/immutable requirements through shared bases) and do not put
the no-Gateway path behind Gateway deployment.

Delete or shrink: protocol wiring in `setBridgehubParams`, vault/router/nullifier setters,
`setChainTypeManagerInServerNotifier`, `updateOwners`; script-side sequencing superseded by
finalization. Keep artifact deployment and transaction submission.

Gate: deploy a fresh ecosystem and CTM, verify all dependency and authority relationships, then
execute an individual-contract operation without legacy bootstrap preparation. Test partial setup,
unauthorized/repeated finalization, incorrect bindings, failed handover and the absence of an
exposed initialization window.

## Batch 5: collapse production preparation and isolate bootstrap

After batches 2–4, use one reusable prepare client for the existing objects. Inputs are explicit
changed members, new artifact references, schedule and any pinned version-specific code. Read
unchanged members and derived payloads from the authoritative objects. A new version should need
custom code only for new protocol behavior, not another version-specific prepare hierarchy.

The recurring output should identify source/target objects, implementation/codehash changes,
required authorities, stage transactions and unresolved external actions. Reporting may format
on-chain facts; it must not decide execution order or recreate the payload.

Keep the pre-registry entry edge in a small named legacy adapter. Do not delete its cut-taking
ABI, handovers or frozen tests while supported chains still require them.

Delete or shrink: the `DefaultCTMUpgrade` / `DefaultCoreUpgrade` inheritance layers, empty version
subclasses, `UpgradeHelperLib` and stage-merging helpers with no consumers. Keep generic Safe
serialization, signer handling and simulation.

Gate: production preparation must demonstrate bootstrap, recurring no-Gateway, individual-member,
L1-only and mixed L1/L2 flows. Assert that every submitted call is a coordinator stage call or an
explicitly required external action.

## Delivery order and review discipline

Batches 2, 3 and 4 each move a class of script-defined action into the flow that already exists,
in any order that keeps a deletion next to its replacement. Batch 5 removes the remaining
scaffolding once those replacements exist.

For every implementation commit: list each removed script responsibility, its former callers and
its new authoritative location; add outcome-based regression tests before removing the reference
path; run the relevant tests and production-path replay, comparing state, authorities, payloads
and deployment lists rather than receipts; refresh generated artifacts when affected, kept
separate enough to review; update the architecture document and the PR description.

Completion means an upgrade can be understood and executed from its on-chain objects plus the
identified approvals, and scripts contain no independent selector lists, payload composition,
protocol-wiring decisions or stage semantics.
