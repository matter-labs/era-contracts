# Upgrade operations: operational policies

Companion to [registry-driven-upgrades.md](registry-driven-upgrades.md). Execution is specified in
[`protocol-docs/ecosystem-upgrade-coordination.md`](../protocol-docs/ecosystem-upgrade-coordination.md);
the objects, executors and bootstrap are in the architecture document; the tooling is in
[the runbook](../l1-contracts/deploy-scripts/upgrade/README.md). This document holds the
operational policies none of those owns.

## ServerNotifier: a one-time handover, then an ordinary CTM-domain proxy

The notifier is a per-CTM proxy. Pre-v35 deployments put it under its OWN `ProxyAdmin`, owned by
the CTM's `ChainAdmin`, and nominated the `ChainAdmin` as its owner. From the registry bootstrap on
it is administered like the rest of the CTM domain: its proxy sits under the CTM-domain `ProxyAdmin`
the CTM executor owns, the CTM executor owns the notifier itself, and its implementation swaps are
ordinary CTM-domain inventory rows of an operation. A fresh ecosystem is deployed in that shape
already: `DeployCTM` puts the notifier under the CTM-domain `ProxyAdmin` and hands it to the CTM
executor.

Getting there is a one-time handover and a PRECONDITION of the bootstrap, because governance cannot
perform the ChainAdmin's half:

| step | authority                                                                 | call                                                                    |
| ---- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| 1    | owner of the notifier's old `ProxyAdmin`                                  | `changeProxyAdmin(notifier, ctmProxyAdmin)`                             |
| 2    | the notifier's current owner                                              | `transferOwnership(ctmExecutor)`                                        |
| 3    | the CTM executor's owner (governance), first call of the bootstrap bundle | `ctmExecutor.forward([notifier.acceptOwnership()])`                     |
| 4    | the bootstrap bundle                                                      | `migrate()` swaps the notifier's implementation through `ctmProxyAdmin` |

Steps 1–2 are RENDERED from live state by the bootstrap prepare
(`CTMUpgrade_v35.serverNotifierHandoverCalls`, a step already done is left out), written to the
prepare output's `[ctm_admin_calls].server_notifier_handover`, declared as `admin`-phase external
actions, and run by protocol-ops right after the prepares (`UpgradeFull::run_ctm_admin_steps`). Step
3 is derived only while the notifier is not yet the executor's, so the bootstrap bundle reverts
until steps 1–2 landed. `RegistryBootstrapMigration.validate()` refuses to run unless the
manifest's mandatory notifier row names the CTM's notifier, the notifier serves the CTM, sits under
`ctmProxyAdmin` and is owned by the CTM executor with no nomination outstanding;
`validateApplied()` keeps checking all of it. `protocol-ops ecosystem verify-bootstrap` reports the
handover as its own prerequisite.

The handover is not undone if the bootstrap is cancelled afterwards: the notifier then simply
belongs to the CTM domain early. A recurring prepare has no admin calls.

## Coordinator succession

Each domain executor stores its coordinator explicitly (`coordinator`, `setCoordinator`); the
coordinator's `CORE_EXECUTOR` is immutable. Replacing the coordinator therefore means deploying a
new `EcosystemUpgradeExecutor` bound to the same `CoreUpgradeExecutor`, then, as the owner of each
domain, pointing it at the successor, then calling the successor's `setCTMExecutor` to bind the CTM
executor back to it. Governance owns the domain executors, so these are direct owner calls, not
`forward`; they change neither executor's bound CTM nor its `ProxyAdmin`.

Rebind before preparing the next operation: the merge derives `execute(operation)` on the
coordinator the CTM executor names at prepare time, and that coordinator's `execute` reverts when it
reaches a domain that has since been pointed elsewhere.

## Monitoring

- **`OperationExecuted(operation)`** on the coordinator: each must name an operation governance
  approved.
- **`CallForwarded(target, value, data)`** on all three executors. Every owner operation outside
  `execute` is a `forward` (see the authority matrix in the architecture document), so each event
  must match a call governance approved; anything else is a bypass of the object-driven path.
- **`CoordinatorChanged`** on the domain executors and **`CTMExecutorChanged`** on the coordinator:
  expected only during coordinator or CTM-executor succession.

## Recovery

An operation either executes completely or reverts; nothing is left pending. What an executed
operation committed stands until a later change replaces it.

**An urgent fix** does not need an operation:

- an ecosystem implementation: `CoreUpgradeExecutor.applyL1Upgrade(coreTransition)` as its owner;
- anything in the CTM domain — an implementation behind the CTM-domain `ProxyAdmin`, a CTM owner
  call: `CTMUpgradeExecutor.forward`;
- a defective transition already committed for a departed version:
  `ChainTypeManager.replaceUpgradeTransition` through `forward` (see "Replacing a committed
  transition" in the coordinator spec).

An operation prepared before such a fix still executes only if every row still departs from the live
implementation (or already runs its `implNew`) and its transition still departs from the CTM's live
release and version; otherwise `execute` reverts (`ProxyUpgradeRowMismatch`, or the transition's
edge check) and the operation is prepared again against the fixed state.

## Migration pauses are incident control

`L1ChainAssetHandler` keeps two migration pauses: the ecosystem-wide `pauseMigration` /
`unpauseMigration` of its owner (governance), and the per-CTM `pauseCTMMigration(ctm)` /
`unpauseCTMMigration(ctm)` of that CTM's current owner — its `CTMUpgradeExecutor`, so governance
reaches it through `forward`. No upgrade path sets or requires either. Where the release-level
migrations ban applies
([chain lifecycle](../protocol-docs/chain-lifecycle.md#v33-chain-migrations-are-explicitly-disabled)),
a migration is refused before either pause is consulted.
