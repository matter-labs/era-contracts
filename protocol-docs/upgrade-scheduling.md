# Upgrade scheduling: `ServerNotifier` and on-chain preconditions

This document is the source of truth for how a chain upgrade is *scheduled* on L1: what the
`ServerNotifier` contract is, the events the server watches, how the scheduled timestamp gates
upgrade execution, and how release-specific upgrade preconditions are enforced at scheduling time.
Contract doc comments reference this file instead of restating the narrative.

Related documents:

- {protocol-docs/chain-lifecycle.md} — chain creation, registration, and migration.

## What `ServerNotifier` is

`ServerNotifier` (`contracts/governance/ServerNotifier.sol`) is a small operational contract that
chain admins use to signal the ZKsync OS server. It is a `TransparentUpgradeableProxy` with a
dedicated `ProxyAdmin` owned by the CTM's ecosystem admin (`chainAdmin`), deliberately *outside*
governance: it can be upgraded operationally without touching the diamond, the CTM, or the
governance timelock. Its `owner()` is the CTM admin on L1; on Gateway it is the aliased L1
governance (`GatewayCTMDeployerCTMBase`).

It emits three events the server watches:

- `MigrateToGateway(chainId, migrationNumber)` / `MigrateFromGateway(chainId, migrationNumber)` —
  migration signals (see {protocol-docs/chain-lifecycle.md}).
- `UpgradeTimestampUpdated(chainId, oldProtocolVersion, upgradeTimestamp)` — emitted by
  `setUpgradeTimestamp`, the upgrade *scheduling* call. The `zksync-os-server` L1 watcher reacts to
  this event by injecting the upgrade transaction into the chain at the scheduled time.

## The scheduling call and the execution gate

`setUpgradeTimestamp(chainId, upgradeTimestamp)` is callable only by the chain's admin (resolved
through `chainTypeManager.getChainAdmin`). It resolves the chain's *current* ("old") protocol
version, requires that the CTM already has an upgrade cut registered for it
(`upgradeCutHash(oldProtocolVersion) != 0`), runs the registered precondition checker for that
version if there is one (see below), and records the timestamp in
`protocolVersionToUpgradeTimestamp[chainId][oldProtocolVersion]`.

The stored timestamp is not merely informational. `AdminFacet.upgradeChainFromVersion` lets a
*validator* (not only the chain admin or the CTM) execute the diamond cut once
`block.timestamp >= timestamp` and the timestamp is non-zero. Scheduling is therefore the moment a
chain commits to the upgrade being executable by its validator — which is exactly why
release-specific prerequisites should be verified then, not only at execution.

## Precondition checkers

Some releases have per-chain prerequisites beyond "the upgrade cut exists". The v32 upgrade of a
ZKsync OS chain is the canonical example: the chain's pre-v31 base-token total supply must have been
backfilled, and a priority-op lower bound proving the backfill *executed* must have been recorded in
the `PriorityOpLowerBound` registry (`RecordPriorityOpLowerBound.s.sol`, run well before the
upgrade executes). `V32UpgradeZKsyncOS.upgrade` enforces all of that at *execution* time — but a
chain that scheduled a timestamp without the prerequisites would only discover the problem when its
upgrade transaction reverts at the scheduled moment.

`ServerNotifier` therefore keeps a per-protocol-version registry of precondition checkers:

- `upgradePreconditionChecker(oldProtocolVersion)` — the registered
  `IUpgradePreconditionChecker`, or zero when the release upgrading *from* that version has no
  extra prerequisites (the default).
- `setUpgradePreconditionChecker(oldProtocolVersion, checker)` — `onlyOwner` (the CTM admin;
  aliased governance on Gateway). Registering a non-zero checker validates the checker's magic
  value (`UPGRADE_PRECONDITION_CHECKER_MAGIC`) with a plain call, so registering a contract that
  does not implement the interface reverts loudly. Registering the zero address deregisters.
- `previewUpgradePreconditions(chainId)` — a view mirroring `setUpgradeTimestamp`'s validation
  without reverting: it returns the error selectors of the checks that would fail (missing upgrade
  cut included), or an empty array when scheduling would pass. Operators and CI use it to dry-run.

When a checker is registered for the chain's current protocol version, `setUpgradeTimestamp` calls
`checker.checkUpgradePreconditions(chainId, zkChain)` after the upgrade-cut check and before
writing the timestamp; the checker reverts with the same specific error the upgrade contract would
revert with at execution time. The event and mapping semantics are unchanged — a scheduling that
passes the checker behaves exactly as before.

Checkers are stateless `view` contracts. They must not mutate state, must not depend on
`msg.sender`, and are keyed by the *old* protocol version because that is what
`setUpgradeTimestamp` resolves and what `upgradeCutHash` is keyed by.

### The v32 checker

`V33UpgradePreconditionChecker` (`contracts/upgrades/V33UpgradePreconditionChecker.sol`) is the
first concrete checker. It enforces, at scheduling time, exactly the prerequisite triple that
`V32UpgradeZKsyncOS.upgrade` enforces at execution time, reusing the same errors so the failures
read identically:

1. `IGetters(zkChain).baseTokenSupportsTotalSupply()` — else `BaseTokenPreV31TotalSupplyNotSet`.
2. `PRIORITY_OP_LOWER_BOUND.recorded(zkChain)` — else `LowerBoundNotRecorded`.
3. `IGetters(zkChain).getFirstUnprocessedPriorityTx() >= lowerBound(zkChain)` — else
   `PriorityQueueNotReady`.

On naming: the in-tree upgrade contracts for this release are `V32Upgrade*` (they take chains *to*
protocol v32 from v31 in production), while the repo's upgrade-env fixtures deploy a genesis at
v32.0.0 and exercise the same contracts as a v32 → v33 upgrade. The checker is named after the
release the fixtures use; its NatSpec points here.

`DefaultUpgradeZKsyncOS` also requires `totalBatchesCommitted == totalBatchesExecuted` at execution
time. The checker deliberately does **not** include that check: batch state is time-sensitive and
would flap at scheduling time (a chain drains its batches close to the upgrade, not days before,
and new batches keep committing), producing spurious scheduling failures with no operational value.

## How a release adds a checker

A release with scheduling-time prerequisites ships the checker in its CTM upgrade script (see
`CTMUpgrade_v31.s.sol`):

1. Deploy the checker alongside the release's per-chain upgrade contract (both typically embed the
   same auxiliary registries as immutables, e.g. `PriorityOpLowerBound`).
2. Append a `setUpgradePreconditionChecker(oldProtocolVersion, checker)` call to the CTM-admin call
   set (`[ctm_admin_calls] server_notifier_upgrade` in the output TOML), *after* the
   `ServerNotifier` implementation upgrade in the same call array — the setter only exists on the
   new implementation, and the calls execute in order.

Fresh ecosystems deploy no checker and register none: a fresh CTM starts at the release's target
version with `DefaultUpgradeZKsyncOS`, so there is no from-version with prerequisites to guard.

Gateway is out of scope for checker registration in this release: the setter works there (the
owner is the aliased governance), but no Gateway release flow registers one, and Gateway is
soft-deprecated.

## Operator flow (v31 → v32 example)

1. Ecosystem prepare: governance/CTM-admin bundles deploy the new contracts, register the upgrade
   cut (`setNewVersionUpgrade`), upgrade the `ServerNotifier` implementation, and register the
   checker for the chains' current version.
2. Per chain, record the priority-op lower bound (`RecordPriorityOpLowerBound.s.sol`) — in a
   transaction well before the chain's upgrade executes.
3. Schedule: the chain admin calls `setUpgradeTimestamp(chainId, ts)` (protocol-ops
   `chain set-upgrade-timestamp`). If step 2 was skipped, this now reverts with the same error the
   upgrade would have reverted with — instead of the failure surfacing at execution time.
4. Execute: at `ts`, the server injects the upgrade transaction and the validator (or the admin)
   calls `upgradeChainFromVersion`.

## Design decisions (and rejected alternatives)

**Where preconditions live.** A per-old-protocol-version registry on `ServerNotifier`, set by its
owner in the release flow. Rejected: (a) making the per-release upgrade contract itself the checker
— it is delegate-called into the diamond and reads diamond storage (`s.*`) directly, so a `view`
entry point callable from outside would need a parallel code path, and the CTM's upgrade pointer is
not per-version; (b) hardcoding the v32 checks in `ServerNotifier` — it is a long-lived proxy
shared across releases, and hardcoding one release's rules means re-upgrading it every release; (c)
putting the checks in `AdminFacet`/CTM — the point of the issue is to stay off the audited
diamond/CTM surface.

**Always-on, no bypass flag.** `setUpgradeTimestamp` keeps its exact signature and semantics (its
ABI is consumed by protocol-ops, partner runbooks, and the calldata-review docs) and *always* runs
the registered checker. Rejected: a `notify(chainId, bool checkPreconditions)` opt-in flag or a
`setUpgradeTimestampUnchecked` variant — a per-call, chain-admin-controlled bypass defeats the
footgun protection for exactly the operator who needs it. The escape hatch is that the CTM admin
(ecosystem level, the party that registered the checker) can deregister it, which is a distinct,
auditable on-chain action (`UpgradePreconditionCheckerSet` with checker = 0).

**Reverting check plus non-reverting preview.** The repo forbids `try`/`catch` and `staticcall`
probing, so a preview cannot be implemented by catching the checker's revert. The checker interface
carries both a reverting `checkUpgradePreconditions` (specific errors, used in the write path) and
a `previewUpgradePreconditions` view returning failed error selectors (used by
`ServerNotifier.previewUpgradePreconditions` for operators and CI). Both build on the same internal
predicates, so they cannot drift within one checker.
