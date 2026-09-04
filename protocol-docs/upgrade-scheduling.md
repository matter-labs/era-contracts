# Upgrade scheduling: `ServerNotifier` and on-chain preconditions

This document describes L1 upgrade scheduling and its release-specific precondition checks. For
chain migration, see {protocol-docs/chain-lifecycle.md}.

## Scheduling

`ServerNotifier` is a `TransparentUpgradeableProxy` used by chain admins to signal the ZKsync OS
server. It emits migration events and `UpgradeTimestampUpdated`, which the server watches to inject
the upgrade transaction at the scheduled time.

`setUpgradeTimestamp(chainId, upgradeTimestamp)`:

1. requires the caller to be the chain admin;
2. resolves the chain's current protocol version;
3. requires an upgrade cut for that version;
4. runs its registered precondition checker, if any; and
5. stores the timestamp under the chain ID and current protocol version.

The timestamp is an execution gate, not only a notification. Once it is non-zero and reached, a
validator can call `AdminFacet.upgradeChainFromVersion`. Checking prerequisites while scheduling
therefore catches failures before the scheduled execution.

The proxy has a dedicated `ProxyAdmin`, separate from governance. Its `owner()` is intended to be
the CTM admin on L1, but fresh deployment currently leaves the transfer from the deployer pending.
Verify `owner()` before an owner-gated operation. On Gateway, the owner is aliased L1 governance.

## Precondition checker registry

`ServerNotifier` maps each old protocol version to an `IUpgradePreconditionChecker`. No registered
checker means the release has no additional scheduling checks.

- `setUpgradePreconditionChecker(oldProtocolVersion, checker)` is owner-only. A non-zero checker
  must return `UPGRADE_PRECONDITION_CHECKER_MAGIC`; zero deregisters it.
- `setUpgradeTimestamp` calls `checkUpgradePreconditions` after checking the upgrade cut and before
  storing the timestamp. A failure uses the same error as the execution-time check.
- `previewUpgradePreconditions(chainId)` reports expected failures as error selectors and omits
  caller and timestamp validation. An empty array means only that the checks it evaluated passed.
  It is not guaranteed to return: CTM, chain, or checker calls can still revert, including for an
  unknown chain or an incompatible dependency.

Checkers are stateless views, do not depend on `msg.sender`, and are keyed by the version being
upgraded from. Registration proves interface intent, not checker health. A checker with a broken
dependency can block scheduling for that version until the owner deregisters it, so the release
flow must exercise the deployed checker against a real chain before registration.

The release flow registers under the CTM's protocol version at prepare time, while scheduling looks
up the chain's current version. A chain lagging behind that version finds no checker for this
release. It can only schedule its earlier version's persistent upgrade cut, whose upgrade contract
retains its own execution-time checks.

## The v32 checker

`V32UpgradePreconditionChecker` mirrors the three prerequisites enforced by
`V32UpgradeZKsyncOS.upgrade`:

1. `baseTokenSupportsTotalSupply()` is true, otherwise `BaseTokenPreV31TotalSupplyNotSet`;
2. the chain has a recorded `PriorityOpLowerBound`, otherwise `LowerBoundNotRecorded`; and
3. `getFirstUnprocessedPriorityTx()` has reached that bound, otherwise `PriorityQueueNotReady`.

The checker intentionally omits the execution-time requirement that committed and executed batch
counts match. Batch drain is transient and may change between scheduling and execution. By
contrast, the priority queue condition is monotonic: the first recorded bound is fixed and the
processed index only increases. Record the bound early; a chain that has not reached it can keep
processing and retry scheduling.

## Release and operator flow

A release with scheduling prerequisites:

1. deploys the checker and any shared auxiliary registry;
2. upgrades `ServerNotifier` and registers the checker through
   `[ctm_admin_calls] server_notifier_upgrade`;
3. records each chain's priority-op lower bound before scheduling;
4. registers the upgrade cut; and
5. lets each chain admin schedule once the checks pass.

The v31 prepare flow serializes the implementation upgrade, an `acceptOwnership()` call when the
notifier owner differs from the proxy-admin owner, and checker registration into one operational
ChainAdmin sequence. When ownership acceptance is needed, generation requires the notifier's
pending owner to be that ChainAdmin and otherwise fails. Execute the complete sequence before
registering the upgrade cut so there is no scheduling window without the checker.

Fresh ecosystems start at the target version and therefore deploy no checker for this transition.
This release also does not register a checker on Gateway.

## Design constraints

The registry belongs on `ServerNotifier` because requirements vary by release. Hardcoding them in
the long-lived notifier would require a new implementation for every release, while placing them
in the diamond or CTM would disturb the audited protocol surface.

Scheduling always runs a registered checker. A chain-admin-controlled bypass would defeat the
protection; deregistration remains an explicit, auditable ecosystem-admin action.

The checker exposes both a reverting enforcement call and a diagnostic preview because the
codebase does not use `try`/`catch` or low-level `staticcall` probing. Both functions share internal
predicates. The preview converts ordinary false predicates into selectors but does not catch
dependency reverts.
