# Ecosystem upgrade coordination

> The canonical description of the coordinator (`EcosystemUpgradeExecutor`), its operation
> object (`EcosystemUpgradeOperation`) and the domain executors it drives.

## Execution domains

`CoreUpgradeExecutor` owns the ecosystem ProxyAdmin and applies one write-once core
upgrade. `CTMUpgradeExecutor` retains ownership of one CTM and its ProxyAdmin.
`EcosystemUpgradeExecutor` coordinates the lifecycle across those domains; it does
not acquire their proxy administration directly.

## Operation commitment

One immutable operation contains `{coreTransition, ctmInfrastructure, transition, timer}`: an
optional ecosystem change, an optional set of CTM-domain proxy rows, an optional chain-version
edge, and the mandatory delay before governance may execute. The coordinator is bound to one core
executor and one CTM executor. The operation describes the change; it does not repeat the executor
addresses. One CTM can manage many chains; their individual upgrades and lagging chain behavior are
unchanged.

Each of the three changes is optional, but an operation must carry at least one: a nonzero core
registry, a nonempty row set, or a nonzero transition. An all-inert inventory does not count — the
mere presence of the container must never make an operation that upgrades nothing look like one
that upgrades something — so such a manifest is refused at construction.

The coordinator stores one pending operation, its stage, and the operation's `manifestHash()` as
stage 0 read it. Later public stages require that exact operation, still serving that hash and a
manifest that hashes to it, so a stale governance transaction cannot act on a replacement proposal
and an object whose answers change between stages is refused.

### One home per responsibility

- **Operation**: infrastructure changes, participation, execution delay.
- **Transition**: what chains upgrade from and to, including their adoption deadline.
- **Release**: what a chain runs.

No transition carries proxy rows, mixed upgrades included. That is what decouples infrastructure
from chain versions: `ValidatorTimelock` is a `CTMContract`, so replacing it used to be a row on a
transition, and a transition refuses unless the protocol version strictly increases. Committing
that edge advanced the CTM's version and every chain then had to adopt it one by one — fleet-wide
work bought for a swap that changes nothing about what any chain runs.

### Infrastructure-only operations

An operation with rows and no transition replaces implementations behind CTM-domain proxies and
moves no version: not the CTM's `protocolVersion`, not its `currentRelease`, no chain's version, no
version deadline and no pending L2 upgrade. It goes through the same three stages, the same
reservations and the same migration pause as any other operation.

Preparation emits one because the version script **declares** it does
(`DefaultCTMUpgrade.upgradeKind`), never because the version numbers happen to match. Two releases
sharing a version number is a consequence of an infrastructure-only edge, not a statement that one
is intended; deriving the kind from it would let a mistyped version silently change what is being
prepared. The declaration comes first and the version relationship is checked against it in both
directions: an infrastructure-only edge whose input names another version is refused, and so is a
chain-release edge whose input forgot to move it.

### The delay and the schedule are independent

The operation's `timer` is the delay before GOVERNANCE may execute stage 1 on L1. The transition's
`upgradeTimestamp` is the earliest a CHAIN may execute its own diamond upgrade, and
`oldProtocolVersionDeadline` is when the departing version stops being usable. The transition
enforces `oldProtocolVersionDeadline >= upgradeTimestamp`; both operands are its own, so moving the
timer away did not touch that invariant.

No relationship between the timer's deadline and `upgradeTimestamp` is enforced, and none should
be. Ordering between the two is already established by the commit itself: a chain cannot upgrade
before `upgradeChain` finds its transition committed on the CTM, which only stage 1 does. A timer
deadline is also not a construction-time value — it is zero until stage 0 starts the timer, and the
timer's owner may extend it within a bound — so there is nothing well-defined to compare a pinned
`upgradeTimestamp` against when the operation is built. And an infrastructure-only operation has no
`upgradeTimestamp` at all, so any such rule would be conditional rather than an invariant.

## Stages

Stage 0 reserves the optional core domain and the CTM, pauses CTM migrations, and starts the
operation's timer. Domains validate their own committed inputs and authorize their coordinator. The
CTM also verifies it is the coordinator's bound executor.

Stage 1 checks the timer deadline, applies the optional core transition, then the CTM leg: the
infrastructure rows first, then the transition's version commit when the operation carries one. The
rows go first because the commit may need a setter that only the implementation this very operation
installs has. Each leg then verifies what it applied before it returns: every row's proxy runs its
`implNew`, and the transition's departure is committed and its target reached. The entire stage is
atomic; no CTM callback applies core upgrades independently. The ordering makes the atomicity case
a specific one: an infrastructure failure cannot roll back a commit that never happened, so what
has to hold is the reverse — rows that already applied are rolled back when the transition leg
then fails.

Stage 2 checks the timer deadline again — a deadline extension made after stage 1 defers
completion too — then releases the optional core reservation and the CTM's, lifting the CTM's
migration pause. It re-reads nothing stage 1 applied: application was verified in the transaction
that made it, and governance may legitimately re-patch an implementation between the stages, or
replace the committed transition (see [Replacing a committed transition](#replacing-a-committed-transition)).
Completion concerns L1 execution; it does not claim that every chain has completed its L2 upgrade.

### Pause policy

The CTM domain is reserved and its migrations paused for EVERY operation, whether or not it carries
a transition. Making the transition optional deliberately did not make reservation or pausing
conditional: an infrastructure change swaps implementations under chains
that could otherwise be migrating, and "does a version edge ride along" is not a signal the
coordinator should infer a safe migration window from. This is the conservative choice for the
first implementation, not a proof that a narrower policy would be wrong.

Abandonment clears reservations without reversing already committed upgrades. Whether migrations
resume is governance's explicit decision, made in the same call: `abandonPendingOperation(true)`
also lifts this CTM's pause through the CTM executor, `false` leaves it held.

## Authorization and recovery

Each domain explicitly authorizes its coordinator (`setCoordinator`). An address
declaring the same governance owner is not evidence of authorization. `beginOperation` reserves an operation. Later callbacks act on that reservation;
CTM execution, completion and abandonment derive their inputs from it. Core execution
checks its registry argument against the reservation. A domain cannot be reserved for
one registry or transition and driven with another. Replacement is forbidden while the domain has a pending
operation. Every other owner operation of a domain — freezing a chain, moving a deadline, replacing a
committed transition — is an ordinary call through the executor's owner-gated, event-logged
`forward`; the executors carry no typed passthroughs for them.

The coordinator's owner binds `ctmExecutor` using `setCTMExecutor` after bootstrap deployment.
The executor must already name this coordinator. The binding cannot change while an operation
is pending; replacing an executor must preserve its `CHAIN_TYPE_MANAGER` identity. To replace
the coordinator, deploy the replacement, change the domain bindings while idle, then bind its
CTM executor before preparing an operation. Governance approval of deployed code and authority
remains required; these binding checks do not authenticate arbitrary executor code.

## Replacing a committed transition

A transition already committed for a departed version can be repaired without moving the CTM:
`ChainTypeManager.replaceUpgradeTransition(expected, replacement)`, called by governance through the
CTM executor's `forward`. It is compare-and-replace — `expected` must be the transition committed
for that departure now, so a stale proposal fails — and it moves neither `protocolVersion` nor
`currentRelease`, so it needs no reservation, pause or timer.

**Recovery invariant.** Every committed departure keeps a path to the CTM's current release. A
replacement therefore departs from the SAME release object (and so the same version) with the same
pinned deadline, lands no earlier than what it replaces, and lands on a release a chain can continue
from: the current release at the current version, otherwise the source release of the transition
committed onward from its target version. Nothing revokes a commitment without replacing it, so
ordinary commits extend the path and replacements only redirect it into the existing one. A
different release object that merely shares a committed version number is never a destination. The
replacement's own `validate()` and the publication of its L2 bytecodes on the CTM's supplier are
checked as on a commit. The invariant is structural: it does not prove that an intermediate
release's L2 effects may be skipped, which remains a review question.

Consequences:

- A chain that has not crossed the departure executes the replacement; `upgradeChain` names the
  committed transition exactly, so the replaced object stops working at once.
- A chain that already crossed keeps the state it reached and continues on its own onward edge: the
  chain-side version check refuses to replay the replacement from the earlier source.
- A deadline change stays a separate `setProtocolVersionDeadline`, which may ride the same `forward`.
- An operation whose transition was replaced between its stages still completes: its departure is
  still committed, by a transition from the same source landing no earlier.
- Legacy-committed departures (pre-registry chains crossing the v35 bootstrap) are repaired by the
  legacy cut setter, which refuses a registry-committed departure.

## Future multi-CTM extension

Multi-CTM participation is deliberately absent from this version. Restore it at these boundaries:

1. Change `OperationManifest.transition` and `ctmInfrastructure` into an ordered list of explicit
   CTM participation records (each CTM's rows beside its own transition), and update
   `EcosystemUpgradeOperation` to reject duplicate CTMs and empty participation.
2. Replace the coordinator's single `ctmExecutor` binding with explicit participant authorization.
   Update stage 0/1/2 and abandonment together, retaining one core execution and atomic rollback.
3. Reserve every participant before execution. The timer is one per operation, so nothing needs to
   deduplicate timer starts. Executor/coordinator replacement must remain blocked by active
   reservations.
4. Update the compose input, Rust/TypeScript readers and bootstrap bindings in the same schema
   change. Test partial failure, duplicate participants, shared timers, and shared-core concurrency.

Keep the domain executor's single-CTM responsibility and the per-chain upgrade APIs. Do not
introduce placeholder lists, loops or a second CTM today solely for this extension.

## Integration gate

Cover the no-change rejection, each change on its own (core-only, infrastructure-only,
transition-only), an infrastructure-only operation moving no version, stage ordering, timer
enforcement at stages 1 and 2, a changed manifest refused after stage 0, rollback of applied rows
when the transition leg fails, a row left off its target failing stage 1, completion after an
infrastructure re-patch and after a transition replacement, abandonment with and without the
unpause, wrong coordinator binding,
rebinding while pending, a different-CTM replacement refusal, valid same-CTM executor succession,
and per-chain upgrades. Exercise the bootstrap binding and recurring operation through production
preparation and both Anvil pipelines.
