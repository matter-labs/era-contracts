# Review guide: deploy-scripts

Style rules for deploy and upgrade scripts, on top of the [root `REVIEW.md`](../../REVIEW.md). Raise breaks as a `nit` that names the rule.

## Version-specific steps go in that version's scripts

A step only one release needs goes in `upgrade/v<minor>/`, not in `upgrade/default-upgrade/`, even behind a version guard. Why: the default upgrade is what every later release inherits, so a guarded one-off stays in it forever.

Seen in: a v35-only deploy step in `DefaultCTMUpgrade` ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268739960)).

## Version gates use `ProtocolVersionFeatures`

To ask "does this version have X", use `utils/ProtocolVersionFeatures.sol` (on the release branches), and add the feature there if it is missing. Don't compare versions inline. Why: one table of when each contract or feature arrived is checked once; inline comparisons are checked at every call site.

Seen in: `AddressIntrospector` ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4294007216), [#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268766656)).

## Address structs are extended, not multiplied

A new deployed address goes into the existing struct for its layer (e.g. `StateTransitionDeployedAddresses` in `utils/Types.sol`). Retire a near-duplicate struct instead of adding another. Why: two structs for the same addresses must be kept in sync by hand.

Seen in: `L1SpecificStateTransitionAddresses` ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268788288)).

## Manual operator steps belong in the scripts

If a runbook tells the operator to run a step by hand that the upgrade scripts could do, make it part of the scripts. Why: a manual step is skipped or done differently on some environment.

Seen in: the proxy-admin split step in `docs/upgrade-operations.md` ([#2673](https://github.com/matter-labs/era-contracts/pull/2673#discussion_r4513102266)).
