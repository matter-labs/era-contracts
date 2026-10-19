# Ecosystem upgrade coordination

> How governance coordinates the upgrade domains: what each domain executor applies, the order
> governance calls them in within one proposal, where ordering and atomicity are enforced, and the
> repair of a committed transition. The objects and the authority model around it are
> [docs/registry-driven-upgrades.md](../docs/registry-driven-upgrades.md).

## Execution domains

An upgrade touches up to two authority domains, each held by one executor that governance owns:

- `CoreUpgradeExecutor` owns the ecosystem `ProxyAdmin` and applies Core-domain proxy upgrade
  transitions to the shared singletons (`applyL1Upgrade`).
- `CTMUpgradeExecutor` is bound by immutables to one CTM and that CTM's `ProxyAdmin`, and owns both.
  It applies CTM-domain proxy upgrade transitions (`applyInfrastructureUpgrade`) and commits
  chain-version transitions on its CTM (`applyCTMUpgrade`).

No executor calls or names another, and no contract spans both domains: governance calls each
executor directly, and the proposal that does so is what coordinates them. One CTM can manage many
chains; their individual upgrades and lagging chain behavior are unchanged.

## What an upgrade applies

Up to three write-once objects, each optional, at least one present:

- a Core-domain `ProxyUpgradeTransition`: source-checked implementation swaps of the ecosystem
  proxies;
- a CTM-domain `ProxyUpgradeTransition`: the same for the CTM-domain proxies, the CTM included;
- a `CTMTransition`: one chain-version edge of the CTM.

A `ProxyUpgradeTransition`'s domain is part of its manifest, so `manifestHash()` and its CREATE2
address commit to it, and its inventory length is the domain's member count rather than a caller's
choice. An object with no participating row is refused at construction: an upgrade that leaves a
domain alone omits that domain's object and its call, so an object present always means a change.

### One home per responsibility

- **Proxy upgrade transition**: infrastructure changes, one domain each.
- **Transition**: what chains upgrade from and to, including their adoption deadline.
- **Release**: what a chain runs.

No transition carries proxy rows, mixed upgrades included. That is what decouples infrastructure
from chain versions: a transition refuses unless the protocol version strictly increases, and
every chain must then adopt the new version one by one, so a `ValidatorTimelock` swap carried by a
transition would buy fleet-wide work for a change to nothing any chain runs.

### Infrastructure-only upgrades

An upgrade with proxy upgrade transitions and no `CTMTransition` replaces implementations behind
proxies and moves no version: not the CTM's `protocolVersion`, not its `currentRelease`, no chain's
version, no version deadline and no pending L2 upgrade. Its proposal carries `applyL1Upgrade` and/or
`applyInfrastructureUpgrade` and no `applyCTMUpgrade`; it executes like any other upgrade.

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
transition committed on the CTM, which only `applyCTMUpgrade` does, so the commit itself orders the
two.

## Execution

Governance executes an upgrade as ONE proposal. Its executor legs are, in this canonical order and
with no other call between them:

1. `CoreUpgradeExecutor.applyL1Upgrade(coreTransition)`;
2. `CTMUpgradeExecutor.applyInfrastructureUpgrade(infrastructureTransition)`;
3. `CTMUpgradeExecutor.applyCTMUpgrade(transition)`.

An upgrade carries the subsequence its objects call for. The ecosystem goes first, so the CTM
domain's code and the commit run against the ecosystem implementations the upgrade installs; the
CTM-domain rows go before the commit, because the commit may need a setter that only an
implementation this very upgrade installs has. Any other call of the proposal is a declared
external action.

Each leg is owner-only and checks its object before acting:

- `applyL1Upgrade` and `applyInfrastructureUpgrade` require the object to have code and to be of the
  executor's own domain (`ProxyUpgradeDomainMismatch`), and every row's `implNew` to have code
  before the first swap. They apply its rows through the executor's bound `ProxyAdmin`, each
  departing from its `expectedOldImpl` or already at its `implNew`, then require every row's proxy
  to run its `implNew`, and emit `L1UpgradeApplied` / `CTMInfrastructureUpgradeApplied`.
- `applyCTMUpgrade` requires the transition to have code and commits it
  (`setNewVersionUpgradeFromTransition`: transition, version and target release together). The
  commit's checks are the CTM's, so a commit sent through `forward` gets them too
  ([Where each check lives](./ecosystem-upgrade.md#where-each-check-lives)): the transition departs
  from the live `currentRelease` and `protocolVersion` and moves the version forward, its engine and
  composer have code, every L2 factory dependency is published on the CTM's `BytecodesSupplier`, and
  the target release passes its `validate()` as it is installed. `applyCTMUpgrade` then requires the
  CTM to commit exactly this transition for its departure and to have reached its target, and emits
  `CTMUpgradeApplied`.

The proposal is the atomicity boundary: one `Governance` or `ProtocolUpgradeHandler` execution runs
its calls in order and reverts all of them when one fails, so rows an earlier leg applied are rolled
back when a later leg fails. Legs sent as separate transactions lose that. Execution concerns L1; it
does not claim that every chain has completed its L2 upgrade.

Chain migrations are not paused around execution. The CTM's migration paths already require the
migrating chain to be at the CTM's protocol version (`forwardedBridgeBurn` / `forwardedBridgeMint`),
and Gateway migration is unsupported, so no migration is in flight for a version commit to wait out.

## Ordering and atomicity

No contract associates the legs of one upgrade. Each guarantee such a contract would give lives
elsewhere:

| Guarantee                                                                           | Where it lives                                                                                                                                                                                                     |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| The ecosystem leg precedes the CTM legs; the CTM-domain rows precede the commit     | The merge derives the legs in canonical order; package verification requires exactly that order, as one contiguous run                                                                                             |
| An upgrade's legs apply together or not at all                                      | One governance proposal execution                                                                                                                                                                                  |
| Each object is applied by its own domain                                            | The proxy entrypoints check the object's code and domain; only the CTM's owner, its executor, can commit a transition                                                                                              |
| The legs governance signs apply the reviewed objects through the reviewed executors | Package verification recovers every (executor, object) pair from the calldata, re-encodes each leg from the reviewed values and reconciles the prepare's summaries; a missing, duplicated or substituted leg fails |
| The CTM legs reach the intended CTM                                                 | The CTM executor's immutable binding, which package verification holds against the independently reviewed CTM and `ProxyAdmin`                                                                                     |
| An executed upgrade is identifiable                                                 | The governance proposal and its transaction, and each leg's domain event                                                                                                                                           |

What no contract enforces: the executors cannot see each other, so none of them can tell whether
another domain's leg is compatible with its own, or whether a leg the upgrade needs was included at
all. That obligation lies with the prepare output and the merge, which derive the legs from what
was deployed, with ordered package verification, and with rehearsing the whole proposal
(`ecosystem upgrade-governance` on a fork, the transaction simulator). Moving it on chain would
take a coordinating contract, which this design deliberately does not have.

An executor's binding stops a call through it from reaching another CTM; it does not tie a
transition to one CTM. A transition carries no CTM pointer, so another CTM on the same release and
version would accept it through its own executor. Verification therefore compares the CTM of the
executor the legs target with the reviewed one.

## Authorization and recovery

The three entrypoints and `forward` are owner-only, and governance owns both executors. Ownership is
the only authorization; there is no binding between executors to configure or keep in sync. Every
other owner operation of a domain — freezing a chain, moving a deadline, replacing a committed
transition — is an ordinary call through the executor's owner-gated, event-logged `forward`; the
executors carry no typed passthroughs for them. Freezing has a second route,
[below](#freezing-a-chain). An urgent fix of one domain is a proposal of the one leg it needs.

A domain moves to a successor executor through the predecessor's `forward`; nothing else names an
executor, so nothing else is rebound. The successor's immutable bindings say which domain it acts
on, not that its code is the reviewed code, so governance approval of its construction remains
required. The procedure is
[executor succession](../docs/upgrade-operations.md#executor-succession).

### Freezing a chain

`ChainTypeManager.freezeChain` and `unfreezeChain` accept two callers: the CTM's owner (its executor,
so governance through `forward`) and the Bridgehub's owner, directly. On a `ProtocolUpgradeHandler`
ecosystem the Bridgehub's owner is the handler, which freezes and unfreezes chains by calling their
CTM itself: the Security Council's soft freeze, hard freeze and unfreeze, the `reinforce*` variants,
and the unfreeze that opens every emergency upgrade. Without the second caller they would stop
reaching a CTM's chains once the bootstrap hands that CTM to its executor. The direct route leaves no
`CallForwarded` entry; the chain's own `Freeze` / `Unfreeze` events remain.

The second caller is safe only while the Bridgehub's owner is the executors' governance, so
`verify-bootstrap` holds `bridgehub.owner()` to the bootstrap manifest's governance before the edge
is signed. The handler wraps each chain's call in `try/catch`, so a chain it failed to freeze goes
unreported: after a freeze, check `isDiamondStorageFrozen()` on every chain and use the handler's
`reinforceFreezeOneChain`, which reverts visibly, for any that is not.

## Replacing a committed transition

A transition already committed for a departed version can be repaired without moving the CTM:
`ChainTypeManager.replaceUpgradeTransition(expected, replacement)`, called by governance through the
CTM executor's `forward`. It is compare-and-replace — `expected` must be the transition committed
for that departure now, so a stale proposal fails — and it moves neither `protocolVersion` nor
`currentRelease`, so it is not an upgrade leg.

**Recovery invariant.** Every committed departure keeps a path to the CTM's current release. A
replacement therefore departs from the SAME release object (and so the same version) with the same
pinned deadline, lands no earlier than what it replaces, and lands on a release a chain can continue
from: the current release at the current version, otherwise the source release of the transition
committed onward from its target version. Nothing revokes a commitment without replacing it, so
ordinary commits extend the path and replacements only redirect it into the existing one. A
different release object that merely shares a committed version number is never a destination.
Every transition's own edge moves the version forward (`VersionEdgeLib`), so the path stays
monotonic. The CTM also refuses the committed transition itself as its replacement, which would
repair nothing. The replacement's engine and composer code and the publication of its L2 bytecodes
on the CTM's supplier are checked as on a commit. The invariant is structural: it does not prove
that an intermediate release's L2 effects may be skipped, which remains a review question.

Consequences:

- A chain that has not crossed the departure executes the replacement; `upgradeChain` names the
  committed transition exactly, so the replaced object stops working at once.
- A chain that already crossed keeps the state it reached and continues on its own onward edge: the
  chain-side version check refuses to replay the replacement from the earlier source.
- A deadline change stays a separate `setProtocolVersionDeadline`, which may ride the same `forward`.
- Legacy-committed departures (pre-registry chains crossing the v35 bootstrap) are repaired by the
  legacy cut setter, which refuses a registry-committed departure and a version nothing was
  committed for.

### Preparing and verifying a replacement

A replacement is prepared like any upgrade: `DefaultTransitionReplacement` runs as the CTM prepare of
`protocol-ops ecosystem upgrade-prepare-all`, named by the upgrade input's
`[transition_replacement] replaced_transition` (and optionally `protocol_version_deadline`). It
deploys the replacement `CTMTransition` exactly as a chain-release prepare deploys its transition —
this run's engine and authored L2 side, bytecodes published on the CTM's supplier — from the replaced
one's source release, deadline and timestamp onto the continuation release, and refuses a stale
`expected` or a replacement that pins the replaced edge unchanged. The package carries one governance
call, `CTMUpgradeExecutor.forward([replaceUpgradeTransition(expected, replacement)])`, optionally
followed by `setProtocolVersionDeadline` in the same `forward`, and no executor leg.
`protocol-ops ecosystem verify-package` recognises it and holds it to the
[recovery invariant](#replacing-a-committed-transition) against live state before the vote.

## Future multi-CTM extension

Multi-CTM upgrades are deliberately absent from this version. Nothing on chain limits an ecosystem to
one CTM: each CTM has its own `CTMUpgradeExecutor`, bound to that CTM and its `ProxyAdmin`, and
registering another CTM binds nothing. The limit is the package's: preparation targets one ZKsync OS
CTM, and package verification admits exactly one reviewed CTM — one `[ctms.*]` section and one CTM
executor, held to that CTM and its `ProxyAdmin`. Restore multi-CTM packages at these boundaries:

1. Preparation and the merge: one CTM leg pair (infrastructure, transition) per participating CTM,
   each on that CTM's own executor, after the one core leg and in a fixed order over the CTMs, so a
   package still means one thing.
2. Package verification: one reviewed CTM, executor binding and `[ctms.*]` section per participant,
   each leg pair held to its own CTM, duplicated participants refused, the whole run still
   contiguous and in canonical order.
3. The Anvil runners' derivation and assertions, in the same change. Test a failing participant's
   leg reverting every leg of the proposal, duplicated participants and a shared core leg.

Keep the domain executor's single-CTM responsibility and the per-chain upgrade APIs. Do not
introduce placeholder lists, loops or a second CTM today solely for this extension.

## Integration gate

- `UpgradeBundleExecution.t.sol` runs the legs as one real `Governance` proposal: all three in
  canonical order with their domain events; each alone (core-only and infrastructure-only moving no
  version, transition-only); the final leg failing after both proxy legs swapped, rolling every swap
  back; a duplicated transition leg; a leg naming the other domain's object; a CTM-domain object
  naming an ecosystem proxy; an undeployed object; a stale transition; a row departing from an
  unexpected implementation or ending off its target; legs sent outside the proposal; an executor
  that does not own its CTM; no migration pause needed or touched.
- `CTMExecutorDomains.t.sol` adds a second real CTM with its own executor: each executor commits on
  its own CTM only and applies rows through its own `ProxyAdmin` only, and a same-CTM successor
  takes over through `forward`.
- protocol-ops: the merge derives the legs in canonical order, each alone, and none for a bootstrap
  or a replacement (`commands/ecosystem/upgrade.rs`); the package loader refuses mixed kinds and
  missing, duplicated, substituted or value-carrying legs and unknown executor selectors
  (`upgrade_verification/registry/package.rs`); `verify_upgrade_calls` refuses a swapped or
  interrupted run, undeclared, duplicated, missing or reordered external actions, and any other call
  reaching an upgrade authority (`upgrade_verification/registry/upgrade.rs`).
- Production preparation and both Anvil pipelines: `UpgradeTestRecurring_Local.t.sol` prepares the
  infrastructure-only, chain-release, mixed and three-leg shapes and the refused ones, and runs each
  as its ordered bundle; `yarn test:upgrade` drives the bootstrap and then recurring hops, verifying
  each merged package, asserting that one transaction emitted every leg's domain event in order and
  checking the state each bundle left;
  `yarn test:upgrade-recurring` runs a hop over objects the harness deploys.
