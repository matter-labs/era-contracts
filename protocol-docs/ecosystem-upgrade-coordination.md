# Ecosystem upgrade coordination

> The canonical description of the coordinator (`EcosystemUpgradeExecutor`), its operation
> object (`EcosystemUpgradeOperation`) and the domain executors it drives.

## Execution domains

`CoreUpgradeExecutor` owns the ecosystem ProxyAdmin and applies one write-once core
upgrade. `CTMUpgradeExecutor` retains ownership of one CTM and its ProxyAdmin.
`EcosystemUpgradeExecutor` coordinates the lifecycle across those domains; it does
not acquire their proxy administration directly.

## Operation commitment

One immutable operation contains `{coreRegistry, transition}`: an optional core registry
and one required CTM transition. The coordinator is bound to one core executor and one CTM
executor. The operation describes the change; it does not repeat the executor addresses.
A core-only change carries a schedule-only transition so it still receives the CTM pause
and timer protections. One CTM can manage many chains; their individual upgrades and lagging
chain behavior are unchanged.

The coordinator stores one pending operation and its stage. Later public stages require
that exact operation, so a stale governance transaction cannot act on a replacement proposal.

## Stages

Stage 0 reserves the optional core domain and the CTM, pauses CTM migrations, and starts
the transition's timer once. Domains validate their own committed inputs and authorize their
coordinator. The CTM also verifies it is the coordinator's bound executor.

Stage 1 checks the timer deadline, applies the optional core registry and then the CTM
transition. The entire stage is atomic; no CTM callback applies core upgrades independently.

Stage 2 verifies and completes the optional core domain, then the CTM. A CTM failure rolls
back core completion. Foreign-admin rows must already be applied. Completion concerns L1
execution; it does not claim that every chain has completed its L2 upgrade.

Abandonment clears reservations without reversing already committed upgrades and leaves
migrations paused. Governance explicitly decides whether to resume them.

## Authorization and recovery

Each domain explicitly authorizes its coordinator (`setCoordinator`). An address
declaring the same governance owner is not evidence of authorization. `beginOperation` reserves an operation. Later callbacks act on that reservation;
CTM execution, completion and abandonment derive their inputs from it. Core execution
checks its registry argument against the reservation. A domain cannot be reserved for
one registry or transition and driven with another. Replacement is forbidden while the domain has a pending
operation. Existing governance operational entrypoints and the logged ordinary-call
recovery path remain available.

The coordinator's owner binds `ctmExecutor` using `setCTMExecutor` after bootstrap deployment.
The executor must already name this coordinator. The binding cannot change while an operation
is pending; replacing an executor must preserve its `CHAIN_TYPE_MANAGER` identity. To replace
the coordinator, deploy the replacement, change the domain bindings while idle, then bind its
CTM executor before preparing an operation. Governance approval of deployed code and authority
remains required; these binding checks do not authenticate arbitrary executor code.

## Future multi-CTM extension

Multi-CTM participation is deliberately absent from this version. Restore it at these boundaries:

1. Change `OperationManifest.transition` into an ordered list of explicit CTM participation
   records, and update `EcosystemUpgradeOperation` to reject duplicate CTMs and empty participation.
2. Replace the coordinator's single `ctmExecutor` binding with explicit participant authorization.
   Update stage 0/1/2 and abandonment together, retaining one core execution and atomic rollback.
3. Restore unique timer starts when transitions share a timer, and reserve every participant
   before execution. Executor/coordinator replacement must remain blocked by active reservations.
4. Update the compose input, Rust/TypeScript readers and bootstrap bindings in the same schema
   change. Test partial failure, duplicate participants, shared timers, and shared-core concurrency.

Keep the domain executor's single-CTM responsibility and the per-chain upgrade APIs. Do not
introduce placeholder lists, loops or a second CTM today solely for this extension.

## Integration gate

Cover required-transition rejection, optional core changes, stage ordering, timer enforcement,
failed-stage rollback, wrong coordinator binding, rebinding while pending, a different-CTM
replacement refusal, valid same-CTM executor succession, and per-chain upgrades. Exercise the
bootstrap binding and recurring operation through production preparation and both Anvil pipelines.
