# Ecosystem upgrade coordination

> The canonical description of the coordinator (`EcosystemUpgradeExecutor`), its operation
> object (`EcosystemUpgradeOperation`) and the domain executors it drives.

## Execution domains

`CoreUpgradeExecutor` owns the ecosystem ProxyAdmin and applies write-once core transitions.
`CTMUpgradeExecutor` retains ownership of one CTM and its ProxyAdmin. `EcosystemUpgradeExecutor`
executes an operation across those domains; it does not acquire their proxy administration
directly.

## Operation commitment

One immutable operation contains `{coreTransition, ctmInfrastructure, ctmTransition}`: an optional
ecosystem change, an optional set of CTM-domain proxy rows and an optional chain-version edge. The
coordinator is bound to one core executor and one CTM executor. The operation describes the change;
it does not repeat the executor addresses. One CTM can manage many chains; their individual
upgrades and lagging chain behavior are unchanged.

Each of the three changes is optional, but an operation must carry at least one: a nonzero core
registry, a nonempty row set, or a nonzero transition. An all-inert inventory does not count — the
mere presence of the container must never make an operation that upgrades nothing look like one
that upgrades something — so such a manifest is refused at construction.

The coordinator is the operation's only reader. `execute` reads `getManifest()` once, requires it to
hash to the operation's `manifestHash()`, and passes that manifest to the domain executors, which
take their legs from it; no domain executor calls the operation, and its per-field getters
(`coreTransition()`, `ctmTransition()`, …) serve tooling and never steer execution.

### One home per responsibility

- **Operation**: infrastructure changes and participation.
- **Transition**: what chains upgrade from and to, including their adoption deadline.
- **Release**: what a chain runs.

No transition carries proxy rows, mixed upgrades included. That is what decouples infrastructure
from chain versions: a transition refuses unless the protocol version strictly increases, and
every chain must then adopt the new version one by one, so a `ValidatorTimelock` swap carried by a
transition would buy fleet-wide work for a change to nothing any chain runs.

### Infrastructure-only operations

An operation with rows and no transition replaces implementations behind CTM-domain proxies and
moves no version: not the CTM's `protocolVersion`, not its `currentRelease`, no chain's version, no
version deadline and no pending L2 upgrade. It is executed like any other operation.

Preparation emits one because the version script **declares** it does
(`DefaultCTMUpgrade.upgradeKind`), never because the version numbers happen to match. Two releases
sharing a version number is a consequence of an infrastructure-only edge, not a statement that one
is intended; deriving the kind from it would let a mistyped version silently change what is being
prepared. The declaration comes first and the version relationship is checked against it in both
directions: an infrastructure-only edge whose input names another version is refused, and so is a
chain-release edge whose input forgot to move it.

### The chain schedule

The transition's `upgradeTimestamp` is the earliest a CHAIN may execute its own diamond upgrade,
and `oldProtocolVersionDeadline` is when the departing version stops being usable. The transition
enforces `oldProtocolVersionDeadline >= upgradeTimestamp`; both operands are its own. Neither is
related to when governance executes: a chain cannot upgrade before `upgradeChain` finds its
transition committed on the CTM, which only `execute` does, so the commit itself orders the two.

## Execution

`execute(operation)` (coordinator owner) is one transaction:

1. It validates the operation (`validate()`: every row's implementation, and the core and CTM
   transitions' own `validate()`) and holds the manifest to `manifestHash()`.
2. When the manifest names a core transition, the core executor applies it (`applyOperation`).
3. The CTM executor applies the CTM leg (`applyOperation`): the infrastructure rows first, then —
   when the operation carries one — the transition's version commit, after checking both of its
   edges against the live CTM. The rows go first because the commit may need a setter that only the
   implementation this very operation installs has.
4. Each leg verifies what it applied before it returns: every row's proxy runs its `implNew`, and
   the CTM commits exactly this transition for its departure and has reached its target version.
5. The coordinator emits `OperationExecuted(operation)`.

Any failure reverts the whole call, so rows that already applied are rolled back when a later leg
fails; no CTM callback applies core upgrades independently. Execution concerns L1; it does not
claim that every chain has completed its L2 upgrade.

Chain migrations are not paused around execution. The CTM's migration paths already require the
migrating chain to be at the CTM's protocol version (`forwardedBridgeBurn` / `forwardedBridgeMint`),
and Gateway migration is unsupported, so no migration is in flight for a version commit to wait out.

## Authorization and recovery

Each domain explicitly authorizes its coordinator (`setCoordinator`, owner only). An address
declaring the same governance owner is not evidence of authorization: `applyOperation` accepts only
the configured coordinator and takes its leg from the manifest the coordinator hash-checked. Outside
an operation, the core executor's owner may apply a whole `CoreTransition` with `applyL1Upgrade`
(the bootstrap edge and recovery). Every other owner operation of a domain — freezing a chain,
moving a deadline, replacing a committed transition — is an ordinary call through the executor's
owner-gated, event-logged `forward`; the executors carry no typed passthroughs for them.

The coordinator's owner binds `ctmExecutor` using `setCTMExecutor` — in the bootstrap bundle, or
when a fresh ecosystem registers its CTM. The executor must already name this coordinator, and a
replacement must preserve its `CHAIN_TYPE_MANAGER` identity. Governance approval of deployed code
and authority remains required; these binding checks do not authenticate arbitrary executor code.
Replacing the coordinator is an operational procedure (`docs/upgrade-operations.md`).

## Replacing a committed transition

A transition already committed for a departed version can be repaired without moving the CTM:
`ChainTypeManager.replaceUpgradeTransition(expected, replacement)`, called by governance through the
CTM executor's `forward`. It is compare-and-replace — `expected` must be the transition committed
for that departure now, so a stale proposal fails — and it moves neither `protocolVersion` nor
`currentRelease`, so it needs no operation.

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
- Legacy-committed departures (pre-registry chains crossing the v35 bootstrap) are repaired by the
  legacy cut setter, which refuses a registry-committed departure.

### Preparing and verifying a replacement

A replacement is prepared like any upgrade: `DefaultTransitionReplacement` runs as the CTM prepare of
`protocol-ops ecosystem upgrade-prepare-all`, named by the upgrade input's
`[transition_replacement] replaced_transition` (and optionally `protocol_version_deadline`). It
deploys the replacement `CTMTransition` exactly as a chain-release prepare deploys its transition —
this run's engine and authored L2 side, bytecodes published on the CTM's supplier — from the replaced
one's source release, deadline and timestamp onto the continuation release, and refuses a stale
`expected` or a replacement that pins the replaced edge unchanged. The package carries one governance
call, `CTMUpgradeExecutor.forward([replaceUpgradeTransition(expected, replacement)])`, optionally
followed by `setProtocolVersionDeadline` in the same `forward`. `protocol-ops ecosystem verify-package`
recognises it and holds it to the [recovery invariant](#replacing-a-committed-transition) against live
state before the vote.

## Future multi-CTM extension

Multi-CTM participation is deliberately absent from this version, so an ecosystem has exactly one
CTM: registering a second one reverts with `CoordinatorCTMMismatch`, because registration binds the
new CTM's executor on the coordinator (`setCTMExecutor`), which accepts only a successor governing
the CTM already bound. Restore it at these boundaries:

1. Change `OperationManifest.ctmTransition` and `ctmInfrastructure` into an ordered list of explicit
   CTM participation records (each CTM's rows beside its own transition), and update
   `EcosystemUpgradeOperation` to reject duplicate CTMs and empty participation.
2. Replace the coordinator's single `ctmExecutor` binding with explicit participant authorization,
   and have `execute` apply every participant's leg after the one core leg, in the same transaction.
3. Update the compose input, Rust/TypeScript readers and bootstrap bindings in the same schema
   change. Test a failing participant reverting every leg, duplicate participants and a shared core
   leg.

Keep the domain executor's single-CTM responsibility and the per-chain upgrade APIs. Do not
introduce placeholder lists, loops or a second CTM today solely for this extension.

## Integration gate

Cover the no-change rejection, each change on its own (core-only, infrastructure-only,
transition-only), an infrastructure-only operation moving no version, a manifest that does not hash
to its commitment, rollback of applied rows when the transition leg fails, a row left off its
target failing execution, a wrong coordinator binding, a different-CTM replacement refusal, valid
same-CTM executor succession, and per-chain upgrades. Exercise the bootstrap bundle and the
recurring operation through production preparation and both Anvil pipelines.
