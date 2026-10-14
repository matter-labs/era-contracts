# Upgrade stage lifecycle: operational policies

Companion to [registry-driven-upgrades.md](registry-driven-upgrades.md). The stages are specified in
[`protocol-docs/ecosystem-upgrade-coordination.md`](../protocol-docs/ecosystem-upgrade-coordination.md);
the objects, executors and bootstrap are in the architecture document; the tooling is in
[the runbook](../l1-contracts/deploy-scripts/upgrade/README.md). This document holds the
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

## The upgrade timer and stage timing

Each operation names its own `GovernanceUpgradeTimer`, deployed by the CTM prepare with
`INITIAL_DELAY` from the input's `governance_upgrade_timer_initial_delay` (zero when absent),
`MAX_ADDITIONAL_DELAY` of two weeks, `TIMER_GOVERNANCE` = the coordinator and `owner` = the
ecosystem admin. Stage 0 starts it — `startTimer` is `onlyTimerAdmin` and one-shot, so stage 0
fails on a timer bound to anyone else or already started — and stages 1 and 2 require
`checkDeadline()`. The owner may extend the deadline with `changeDeadline`, at most
`MAX_ADDITIONAL_DELAY` past the initial one; an extension made after stage 1 defers stage 2 too.
The bootstrap edge predates the coordinator, so its timer is bound to governance, started by a
declared stage-0 call and checked by `migrate()`.

The timer is the delay before GOVERNANCE may execute; it gives chains no time. No chain can upgrade
before stage 1 commits the transition, and a chain's own window is the transition's
`upgradeTimestamp` and `oldProtocolVersionDeadline` (see "The delay and the schedule are
independent" in the coordinator spec).

**Delay policy.** No minimum delay is enforced on-chain, and a zero `INITIAL_DELAY` — all three
stages in one block — is acceptable. The stage-0 pause exists only to let in-flight
settlement-layer migrations drain before the version moves; from v33 on no Gateway is deployed, so
there are none, and an atomic run leaves no state in which an operation sits reserved after stage 0
or stage 1. A nonzero delay is needed only where a settlement
layer exists, or where the timer owner must be able to hold stage 1 with `changeDeadline`.

**Timing between stages.** Stage 1 is admissible once the deadline has passed. Stage 2 checks the
deadline again and releases the reservations and the migration pause; it does not wait for any
chain's L2 upgrade, so it follows stage 1 directly. Until it runs, the CTM's migrations stay paused,
no other operation can start and neither domain executor can be rebound.

## Coordinator succession

Each domain executor stores its coordinator explicitly (`coordinator`, `setCoordinator`); the
coordinator's `CORE_EXECUTOR` is immutable. Replacing the coordinator therefore means deploying a
new `EcosystemUpgradeExecutor` bound to the same `CoreUpgradeExecutor`, then, as the owner of
each domain, pointing it at the successor, then calling the successor coordinator's
`setCTMExecutor` to bind the CTM executor back to it. `setCoordinator` is refused while a domain is reserved,
so one operation is prepared, executed and completed by one coordinator; do it between upgrades,
before the prepare, because every operation's timer is bound to the coordinator that will start
it. Governance owns the domain executors, so this is a direct owner call, not `forward`. It changes
neither executor's bound CTM nor its `ProxyAdmin`.

## Monitoring

- **Operations left pending.** The coordinator's `pendingOperation()` and `pendingStage()`, and its
  `OperationPrepared` / `OperationExecuted` / `OperationCompleted` / `OperationAbandoned` events.
  Alert when an operation stays `Prepared` past its timer's `deadline()`, or `Executed` longer than
  it takes to submit stage 2: either holds the CTM's migrations paused and blocks every other
  operation and rebinding. Resolve it with the next stage or by abandoning it.
- **`CallForwarded(target, value, data)`** on all three executors. Every owner operation outside the
  lifecycle is a `forward` (see the authority matrix in the architecture document), so each event
  must match a call governance approved; anything else is a bypass of the object-driven path.
- **`DeadlineChanged`** on a pending operation's timer: the ecosystem admin moved stages 1 and 2.

## Abandonment and recovery

`abandonPendingOperation(unpauseMigrations)` (coordinator owner) frees every reservation and the
lifecycle slot; what stage 1 already committed stands (the semantics are in the coordinator spec).
With `unpauseMigrations` the CTM executor lifts this CTM's pause in the same call; without it the
pause stays held until governance lifts it through the executor's `forward` to
`unpauseCTMMigration`. A transition committed for a departed version is repaired with
`ChainTypeManager.replaceUpgradeTransition` through `forward` (see "Replacing a committed
transition" in the coordinator spec).

**An urgent fix while an operation is pending.** The lifecycle blocks none of governance's other
paths, so the fix does not wait for it:

1. If stage 1 has not run, do not submit it; the timer's owner can also hold it with
   `changeDeadline`.
2. Apply the fix outside the lifecycle: an ecosystem implementation with
   `CoreUpgradeExecutor.applyL1Upgrade(coreTransition)` as its owner, which a reservation does not
   block; anything in the CTM domain — an implementation behind the CTM-domain `ProxyAdmin`, a CTM
   owner call, a defective committed transition — through `CTMUpgradeExecutor.forward`.
3. Reconcile the pending operation. After stage 1 it still completes: stage 2 re-reads nothing.
   Before stage 1 it can execute only if every row still departs from the live implementation (a
   proxy the fix moved anywhere but the row's `implNew` reverts stage 1 with
   `ProxyUpgradeRowMismatch`) and its transition still departs from the CTM's live release and
   version. Otherwise abandon it and prepare a new operation against the fixed state, with a new
   timer: a timer starts once.

A fix may instead ship as an operation of its own once the pending one is abandoned; with a zero
delay its three stages land in one block.
