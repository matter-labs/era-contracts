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
  the executor, so after an abandonment it reaches `unpauseCTMMigration` through the executor's
  owner-gated `forward`, which logs the call.
- **The release-level ban is checked first.** `CHAIN_MIGRATIONS_ENABLED` is false in this release,
  so on a production handler a migration reverts with `ChainMigrationsDisabled` before the pause is
  consulted. The pause gate is exercised against the Dev handlers, which re-enable migrations.

## ServerNotifier: a row under a foreign admin

The notifier is a per-CTM proxy but sits under its OWN `ProxyAdmin`, owned by the CTM's
`ChainAdmin` — not under the CTM-domain `ProxyAdmin` the executor owns. Its implementation swap
is therefore the one inventory row whose `admin` field is set (the row format is described with
the objects in the architecture document). Two operating modes follow, both expressible as
on-chain state:

- **Hand the notifier's `ProxyAdmin` to the `CTMUpgradeExecutor`.** The row rides stage 1 like
  any other CTM-domain row.
- **Keep it with the `ChainAdmin`.** Stage 1 leaves the row to that administrator
  (`ProxyRowLeftToAdministrator`), and the ChainAdmin's own call must land before stage 2, which
  requires the row applied. This is the shape today.

The ChainAdmin's call is RENDERED from the pinned row (`DefaultCTMUpgrade.prepareUpgradeServerNotifierCall`,
written to the prepare output's `[ctm_admin_calls]` and declared as an `admin`-phase external
action): the same `ProxyAdmin` call `ProxyUpgradeRowLib.applyRows` makes for that row —
`upgradeAndCall` with the fixed `initializeUpgrade()` when the row reinitializes, a plain
`upgrade` otherwise — so the administrator executes exactly the swap governance reviewed and the
prepare defines the swap nowhere else (`ServerNotifierRowCall.t.sol`). protocol-ops runs that
call right after the prepares (`UpgradeFull::run_ctm_admin_steps`). On the bootstrap edge the row
is pinned by the migration, `migrate()` leaves it to the ChainAdmin, and both `validate()` (a row
already at `implNew` passes) and `validateApplied()` account for it.

One footgun: never transfer a foreign admin to the bootstrap MIGRATION — it hands onward only the
CTM-domain `ProxyAdmin`, so an admin parked on the spent one-shot object has no way out. The
executor is the long-lived owner.

## L2 delegate composition

The manifest carries no delegate calldata. `AuthoredL2Plan` supplies the delegate bytecode info,
extra bytecode infos and a codehash-pinned `IL2DelegateCalldataComposer` (v34:
`L2V34DelegateCalldataComposer`). `L2PlanLib` constructs the deployments, delegate address and
factory-dependency hashes from those inputs.

`CTMUpgradeComposer` asks the pinned composer for final calldata using the target release,
Bridgehub and chain ID. The v34 composer reads the chain-specific force-deployment data directly;
the execution engine no longer decodes placeholders or understands the v34 delegate ABI.

## The upgrade timer

Each transition pins its own `GovernanceUpgradeTimer`, deployed by the CTM prepare with
`TIMER_GOVERNANCE` = the coordinator and `owner` = the ecosystem admin. Stage 0 checks the binding
and starts each distinct timer once, including when several legs share it; stage 1 requires `checkDeadline()` for every leg. The ecosystem admin keeps the
bounded extension right through the timer's own `changeDeadline`, capped at
`deadline + MAX_ADDITIONAL_DELAY` (two weeks in the prepare). That right is separately governed
and stays explicit. The bootstrap edge predates the coordinator, so its timer is bound to
governance and started as a declared external action.

## Coordinator succession

Each domain executor stores its coordinator explicitly (`coordinator`, `setCoordinator`); the
coordinator's `CORE_EXECUTOR` is immutable. Replacing the coordinator therefore means deploying a
new `EcosystemUpgradeExecutor` bound to the same `CoreUpgradeExecutor`, then, as the owner of
each domain, pointing it at the successor. `setCoordinator` is refused while a domain is reserved,
so one operation is prepared, executed and completed by one coordinator; do it between upgrades,
before the prepare, because every transition's timer is bound to the coordinator that will start
it. Governance owns the domain executors, so this is a direct owner call, not `forward`.

This changes neither an executor's bound CTM / `ProxyAdmin` nor its object codehash anchors.
Replacing an object schema or its accepted codehash is a separate migration and must not be
simulated by regenerating already-deployed source state.

## Abandonment and recovery

`abandonPendingOperation` (coordinator owner) frees every reservation and the lifecycle slot;
what stage 1 already committed stands, and every CTM pause stays held (the semantics are in the
coordinator spec). Recovery is then governance's explicit decision: prepare a corrected operation,
and resume migrations — per CTM through the executor's `forward` to `unpauseCTMMigration`, or
ecosystem-wide with `unpauseMigration`. Authority the executors hold stays reachable through
`forward` in every case, so a stuck lifecycle never strands the CTM or its `ProxyAdmin`.
