# Review guide: l1-contracts tests

Style rules for tests, on top of the [root `REVIEW.md`](../../REVIEW.md) and the "Testing Guidelines" in [`AGENTS.md`](../../AGENTS.md). Raise breaks as a `nit` that names the rule. Changes to test harnesses, fixtures and foundry profiles also get the checks in [`.github/REVIEW.md`](../../.github/REVIEW.md).

## Upgrade tests follow the current release

Upgrade tests read the release they upgrade to from config (`configs/genesis/<vm>/latest.json` and what derives from it), with no version constant to bump. Why: a test pinned to the last release keeps passing while it no longer tests the next one.

Seen in: `UpgradeTest_Local` ([#2636](https://github.com/matter-labs/era-contracts/pull/2636#discussion_r4410484618), [#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268828640)).

## A new upgrade case extends the existing integration test

Add an upgrade scenario to the shared upgrade integration test (`UpgradeTest_Local` and its shared base) rather than a new `UpgradeTest*_Local` file with its own setup. Why: each copy of the setup drifts from the real flow, and the real flow is the one that ships.

Seen in: `UpgradeTestSplitProxyAdmin_Local` ([#2673](https://github.com/matter-labs/era-contracts/pull/2673#discussion_r4513497848)).

## Tests whose subject is gone are deleted

When the code or release a test covers is gone, delete the test, or the half of it that no longer applies. Don't keep it green with stubs. Why: it costs CI time and suggests coverage that isn't there.

Seen in: `ServerNotifierHandover.t.sol` ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444983837)), `EraStub` ([#2673](https://github.com/matter-labs/era-contracts/pull/2673#discussion_r4513494650)), `L1MessageRootDev` ([#2561](https://github.com/matter-labs/era-contracts/pull/2561#discussion_r4229432371)).
