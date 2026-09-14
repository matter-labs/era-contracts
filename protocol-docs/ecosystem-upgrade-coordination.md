# Ecosystem upgrade coordination

> The canonical description of the coordinator (`EcosystemUpgradeExecutor`), its operation
> object (`EcosystemUpgradeOperation`) and the domain executors it drives.

## Execution domains

`CoreUpgradeExecutor` owns the ecosystem ProxyAdmin and applies one pinned core
upgrade. `CTMUpgradeExecutor` retains ownership of one CTM and its ProxyAdmin.
`EcosystemUpgradeExecutor` coordinates the lifecycle across those domains; it does
not acquire their proxy administration directly.

## Operation commitment

One immutable operation specifies an optional core registry and an ordered list of
CTM executor / transition pairs. A pair binds a transition to the executor that
will apply it. The core registry is named on the operation and nowhere else:
transitions describe their CTM's change, the operation commits the association
with the ecosystem change. Reject duplicate CTMs and empty operations. All objects
must pass their existing provenance and codehash checks before preparation changes
state. The operation is an upgrade description, not a deployment inventory.

The coordinator stores one pending operation and its stage. Later stages accept
only that operation. An individual CTM upgrade is a one-element operation without
a core leg. Core-only upgrades need an explicit ecosystem pause and timer policy;
they must not silently bypass preparation because the CTM list is empty.

## Stages

Stage 0 reserves every participant, pauses the affected migrations, and starts the
pinned timers (each timer once — legs may share one). Each domain executor validates
its own leg when it is reserved (`beginOperation(operation)`, reading the leg from
the operation): the core executor pins and validates the registry, the CTM executor
pins and validates the transition and checks both version edges, then pauses its
CTM's migrations — ChainAssetHandler requires the registered CTM owner for that.
Authority is the domain's to enforce: every callback is `onlyCoordinator`, and the
coordinator performs no pre-check of its own. Timer-start authority belongs to the
coordinator.

Stage 1 checks all deadlines and pause preconditions before applying the core leg
once, followed by the CTM legs in committed order. The entire stage is atomic.
No CTM callback may apply the core leg independently.

Stage 2 completes every domain in one transaction: each verifies its own result
(`completeOperation`) before releasing its reservation and, for a CTM, its migration
pause. A later domain's refusal rolls back the earlier releases, so no pause is
lifted unless every leg verified. Foreign-admin rows must be applied before
completion. Completion concerns L1 execution; it does not claim that all chains have
completed their L2 upgrades.

Abandonment clears reservations without reversing already committed upgrades and
leaves migrations paused. Governance explicitly decides whether to resume them.

## Authorization and recovery

Each domain explicitly authorizes its coordinator (`setCoordinator`). An address
declaring the same governance owner is not evidence of authorization. Domain
callbacks require that the coordinator is executing the exact operation reserved;
the leg is read from that operation, never re-supplied, so a domain cannot be
reserved for one registry or transition and driven with another. Replacement is
forbidden while the domain has a pending operation. Existing governance operational
entrypoints and the logged ordinary-call recovery path remain available.

## Integration gate

The change must migrate constructor/deployment wiring, bootstrap owner and binding
checks, production stage bundles, Rust package verification, centralized ABIs,
Foundry fixtures, both Anvil pipelines, and architecture documentation together.
Required scenarios include one CTM, multiple CTMs sharing one core change, duplicate
participants, wrong authority, different operation between stages, a failure in a
later CTM rolling back the core and earlier CTMs, foreign-admin completion,
abandonment, and a patch while a previous L2 transaction is pending.
