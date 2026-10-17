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
ordinary rows of a CTM-domain `ProxyUpgradeTransition`. A fresh ecosystem is deployed in that shape
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

## Executor succession

Each domain executor is bound by immutables to what it governs (`CoreUpgradeExecutor.PROXY_ADMIN`;
`CTMUpgradeExecutor.CHAIN_TYPE_MANAGER` and `CTM_PROXY_ADMIN`), and nothing names an executor in
return. Replacing one is therefore a handover of its domain to a successor constructed over the
same bindings and owned by governance, through the predecessor's `forward`:

- the core domain: `ProxyAdmin.transferOwnership(successor)` on the ecosystem `ProxyAdmin`;
- a CTM domain: `transferOwnership(successor)` on the CTM, its `ProxyAdmin` and the ServerNotifier;
  the successor's `acceptCTMOwnership()` (permissionless, gated by the nomination) and a
  `forward([notifier.acceptOwnership()])` complete the two-step handovers.

Hand over before preparing the next upgrade: the prepares name the executor that holds each domain
at prepare time (the ecosystem `ProxyAdmin`'s owner, the CTM's owner), and the merge derives the
legs on it. A leg sent to an executor that no longer holds its domain reverts, and the whole
proposal with it. Package verification re-derives an executor from its `[upgrade_executors]`
record, so the successor's deployment must leave one (see "Provenance and validation" in the
architecture document).

## Monitoring

- **`L1UpgradeApplied(coreTransition)`** on the core executor, and
  **`CTMInfrastructureUpgradeApplied(infrastructureTransition)`** and
  **`CTMUpgradeApplied(transition, oldVersion, newVersion)`** on the CTM executor: each must name an
  object governance approved, and the legs of one upgrade appear in one transaction — the execution
  of its governance proposal — in canonical order. `ProxyImplementationUpgraded(proxy, newImpl)`
  follows each actual swap. A leg in any other transaction, or a proposal carrying only part of a
  package's legs, is not the reviewed upgrade.
- **`CallForwarded(target, value, data)`** on both executors. Every owner operation outside the
  upgrade entrypoints is a `forward` (see the authority matrix in the architecture document), so each
  event must match a call governance approved; anything else is a bypass of the object-driven path.
- **Ownership changes** (`OwnershipTransferStarted` / `OwnershipTransferred`) on the executors, the
  CTM, both `ProxyAdmin`s and the ServerNotifier: expected only during executor succession or
  [governance self-migration](governance-self-migration.md).

## Recovery

A governance proposal either executes completely or reverts; nothing is left pending. What an
executed upgrade committed stands until a later change replaces it.

**An urgent fix** is a proposal of the one call it needs:

- an ecosystem implementation: `CoreUpgradeExecutor.applyL1Upgrade(coreTransition)`;
- a CTM-domain implementation: `CTMUpgradeExecutor.applyInfrastructureUpgrade(infrastructureTransition)`;
- any other CTM-domain change, such as a CTM owner call: `CTMUpgradeExecutor.forward`;
- a defective transition already committed for a departed version:
  `ChainTypeManager.replaceUpgradeTransition` through `forward` (see "Replacing a committed
  transition" in the coordination spec).

An upgrade prepared before such a fix still executes only if every row still departs from the live
implementation (or already runs its `implNew`) and its transition still departs from the CTM's live
release and version; otherwise its leg reverts (`ProxyUpgradeRowMismatch`, or the transition's edge
check), the whole proposal with it, and the upgrade is prepared again against the fixed state.

## Migration pauses are incident control

`L1ChainAssetHandler` keeps two migration pauses: the ecosystem-wide `pauseMigration` /
`unpauseMigration` of its owner (governance), and the per-CTM `pauseCTMMigration(ctm)` /
`unpauseCTMMigration(ctm)` of that CTM's current owner — its `CTMUpgradeExecutor`, so governance
reaches it through `forward`. No upgrade path sets or requires either. Where the release-level
migrations ban applies
([chain lifecycle](../protocol-docs/chain-lifecycle.md#v33-chain-migrations-are-explicitly-disabled)),
a migration is refused before either pause is consulted.
