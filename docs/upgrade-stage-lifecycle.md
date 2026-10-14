# Upgrade stage lifecycle: operational policies

Companion to [registry-driven-upgrades.md](registry-driven-upgrades.md). This document started as
the specification for moving the scripted stage-0/1/2 flow on-chain; that move is complete. The
stages now live on the coordinator (`EcosystemUpgradeExecutor.stage0/1/2(operation)`) and are
specified in [`protocol-docs/ecosystem-upgrade-coordination.md`](../protocol-docs/ecosystem-upgrade-coordination.md);
the objects, executors and bootstrap are in the architecture document; the tooling is in
[the runbook](../l1-contracts/deploy-scripts/upgrade/README.md). What remains here are the
operational policies the lifecycle relies on and neither of those documents owns.

## Migration pause: two pauses, on two authorities

The stages stop chain migrations while a CTM's version moves — a chain crossing settlement layers
mid-edge would land with an inconsistent version, which is why
`ChainTypeManager._commitVersionEdge` refuses to run unpaused.

The state lives on the shared `L1ChainAssetHandler`, because that is where migrations execute
(`bridgeBurn` / `bridgeMint`), and it is keyed on TWO axes because two authorities have a
legitimate reason to stop migrations:

| pause                                                 | who writes it                                                                                                          | scope                                            |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `pauseMigration` / `unpauseMigration`                 | the handler's owner (ecosystem governance)                                                                             | every chain, whatever its CTM — incident control |
| `pauseCTMMigration(ctm)` / `unpauseCTMMigration(ctm)` | that CTM's current owner — during an upgrade its bound `CTMUpgradeExecutor`, in `beginOperation` / `completeOperation` | chains under that CTM                            |

`migrationPausedFor(ctm)` is the OR of the two, and the gate on the migration entrypoints asks it
about the CTM the migrating chain belongs to. A chain may only migrate between settlement layers
under its OWN CTM (`SLHasDifferentCTM`), so one CTM is the whole answer.

Authority for the per-CTM pause is DERIVED, not stored: a caller qualifies by being the current
owner of a CTM the Bridgehub has registered. There is no allowlist to maintain, replacing an
executor moves the ability with the ownership, and no CTM-domain state sits in the
ecosystem-domain handler.

Consequences:

- One CTM's stage 2 lifts only that CTM's pause. An ecosystem pause governance holds — or another
  CTM's upgrade — is untouched (`CTMUpgradeLifecycle.t.sol`, `L1ChainAssetHandlerMigrationPause.t.sol`).
- **Governance cannot clear a CTM's pause directly.** Only that CTM's owner can. Governance owns
  the executor, so it lifts the pause with `abandonPendingOperation(true)` when abandoning, or
  through the executor's owner-gated `forward` to `unpauseCTMMigration`, which logs the call.
- **The release-level ban is checked first.** `CHAIN_MIGRATIONS_ENABLED` is false in this release,
  so on a production handler a migration reverts with `ChainMigrationsDisabled` before the pause is
  consulted. The pause gate is exercised against the Dev handlers, which re-enable migrations.

## ServerNotifier: a one-time handover, then an ordinary CTM-domain proxy

The notifier is a per-CTM proxy. Pre-v35 deployments put it under its OWN `ProxyAdmin`, owned by
the CTM's `ChainAdmin`, and nominated the `ChainAdmin` as its owner. From the registry bootstrap on
it is administered like the rest of the CTM domain: its proxy sits under the CTM-domain `ProxyAdmin`
the CTM executor owns, the CTM executor owns the notifier itself, and its implementation swaps are
ordinary CTM-domain inventory rows applied in stage 1 (`DeployCTM.deployServerNotifier` deploys
fresh ecosystems under the CTM-domain `ProxyAdmin` already).

Getting there is a one-time handover and a PRECONDITION of the bootstrap, because governance cannot
perform the ChainAdmin's half:

| step | authority                                      | call                                                                    |
| ---- | ---------------------------------------------- | ----------------------------------------------------------------------- |
| 1    | owner of the notifier's old `ProxyAdmin`       | `changeProxyAdmin(notifier, ctmProxyAdmin)`                             |
| 2    | the notifier's current owner                   | `transferOwnership(ctmExecutor)`                                        |
| 3    | the CTM executor's owner (governance), stage 0 | `ctmExecutor.forward([notifier.acceptOwnership()])`                     |
| 4    | stage 1                                        | `migrate()` swaps the notifier's implementation through `ctmProxyAdmin` |

Steps 1–2 are RENDERED from live state by the bootstrap prepare
(`CTMUpgrade_v35.serverNotifierHandoverCalls`, a step already done is left out), written to the
prepare output's `[ctm_admin_calls].server_notifier_handover`, declared as `admin`-phase external
actions, and run by protocol-ops right after the prepares (`UpgradeFull::run_ctm_admin_steps`). Step
3 is the first call of the derived stage 0 while the notifier is not yet the executor's, so stage 0
reverts until steps 1–2 landed. `RegistryBootstrapMigration.validate()` refuses to run unless the
manifest's mandatory notifier row names the CTM's notifier, the notifier serves the CTM, sits under
`ctmProxyAdmin` and is owned by the CTM executor with no nomination outstanding;
`validateApplied()` keeps checking all of it. `protocol-ops ecosystem verify-bootstrap` reports the
handover as its own prerequisite.

The handover is not undone if the bootstrap is cancelled afterwards: the notifier then simply
belongs to the CTM domain early. A recurring prepare has no admin calls.

## L2 delegate composition

The manifest carries no delegate calldata. `AuthoredL2Plan` supplies the delegate bytecode info,
extra bytecode infos and a codehash-pinned `IL2DelegateCalldataComposer` (by default
`L2DefaultDelegateCalldataComposer`). `L2PlanLib` constructs the deployments, delegate address and
factory-dependency hashes from those inputs.

`CTMUpgradeComposer` asks the pinned composer for final calldata using the target release,
Bridgehub and chain ID. The default composer reads the chain-specific force-deployment data directly;
the execution engine no longer decodes placeholders or understands the delegate ABI.

## The upgrade timer

Each operation pins its own `GovernanceUpgradeTimer`, deployed by the CTM prepare with
`TIMER_GOVERNANCE` = the coordinator and `owner` = the ecosystem admin. Stage 0 starts it once —
`startTimer` is `onlyTimerAdmin`, so a timer anybody else could have started early fails the stage;
stages 1 and 2 require `checkDeadline()`, so an extension made after stage 1 defers completion too.
It is the delay before GOVERNANCE may execute, and is independent of the transition's chain-side
`upgradeTimestamp` (see the coordinator spec). The ecosystem admin keeps the bounded extension right through the timer's own
`changeDeadline`, capped at
`deadline + MAX_ADDITIONAL_DELAY` (two weeks in the prepare). That right is separately governed
and stays explicit. The bootstrap edge predates the coordinator, so its timer is bound to
governance and started as a declared external action.

## Coordinator succession

Each domain executor stores its coordinator explicitly (`coordinator`, `setCoordinator`); the
coordinator's `CORE_EXECUTOR` is immutable. Replacing the coordinator therefore means deploying a
new `EcosystemUpgradeExecutor` bound to the same `CoreUpgradeExecutor`, then, as the owner of
each domain, pointing it at the successor, then calling the successor coordinator's
`setCTMExecutor` to bind the CTM executor back to it. `setCoordinator` is refused while a domain is reserved,
so one operation is prepared, executed and completed by one coordinator; do it between upgrades,
before the prepare, because every operation's timer is bound to the coordinator that will start
it. Governance owns the domain executors, so this is a direct owner call, not `forward`.

This changes neither an executor's bound CTM / `ProxyAdmin` nor its object codehash anchors.
Replacing an object schema or its accepted codehash is a separate migration and must not be
simulated by regenerating already-deployed source state.

## Abandonment and recovery

`abandonPendingOperation(unpauseMigrations)` (coordinator owner) frees every reservation and the
lifecycle slot; what stage 1 already committed stands (the semantics are in the coordinator spec).
With `unpauseMigrations` the CTM executor lifts this CTM's pause in the same call; without it the
pause stays held until governance lifts it — per CTM through the executor's `forward` to
`unpauseCTMMigration`, or ecosystem-wide with `unpauseMigration`. A transition committed for a
departed version is repaired with `ChainTypeManager.replaceUpgradeTransition` through `forward`
(see "Replacing a committed transition" in the coordinator spec). Every other CTM owner operation
goes through `forward` too, so authority the executors hold stays reachable in every case and a
stuck lifecycle never strands the CTM or its `ProxyAdmin`.
