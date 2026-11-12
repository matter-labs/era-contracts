# Review guide: build, CI and test plumbing

What to check when a change touches workflows, `package.json` scripts, `foundry*.toml` profiles, Dockerfiles, test harnesses or fixtures. Breaks here are silent: a gate that can't fail looks like a gate that passes, so per-PR CI won't catch them. Raise them as findings, not nits. For style rules see the [root `REVIEW.md`](../REVIEW.md); for getting CI green see [`docs/ai-review/docs/ci-green.md`](../docs/ai-review/docs/ci-green.md).

## What does the gate actually verify?

For every gate a change adds or edits, name an input that turns it red. It should fail when the thing it guards is false (the run passed, on this commit, from the right source), not only when an input is malformed. A green run of a new gate proves nothing; ask how it was seen to fail.

Example: the release gate in `build-docker.yaml` took a zksync-os-integration-tests run URL and checked only its format. It now requires that the run passed and that its `Cargo.lock` pins era-contracts at the commit being built ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4396866664)).

## Do two builds or steps share an output or cache directory?

A profile, build or step that writes different artifacts to the same `out/`, cache, `script-out/` or fixture directory as another one means the last writer wins, and later readers can't tell. A foundry profile that changes bytecode (metadata, optimizer, compiler settings) gets its own `out` and `cache_path`. Check every reader of the shared directory, not only the step that wrote it.

Example: the `anvil-interop` profile (no CBOR metadata) built into the default profile's `out/` and `cache-forge`. After a previous-release test run, `copy-to-zkstack-out`, the hashes, the selectors and the anvil harness read metadata-off bytecode ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4442412494), `l1-contracts/package.json`).

## Is each side of a comparison built like production?

A test that compares two builds made the same non-production way passes on any difference that only production sees. Name the production check the test stands in for, and confirm the test feeds it the same kind of input.

Example: the upgrade tests compared metadata-off builds on both sides, while the real prepare compares full code hashes. A metadata-only change (one new constant in `Config.sol` changed 94 of 97 hashes on #2592) would pass every per-PR check and fail first at the stage calldata prepare ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4442412499), `PreviousReleaseFixture.sol`). The fix was a per-PR test that runs the prepare's reuse check against the previous release's frozen `AllContractsHashes.json`.

## Does a changed test still test what its name says?

When a test loses setup, stages or assertions, read its name, its suite and the PR description against what is left. Either restore the check or say in the PR what is no longer covered.

Example: with the bootstrap stages gone, `yarn test:upgrade` stopped sending an interop message after the upgrade, so the upgrade test no longer showed that interop works afterwards ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4515415086)). Likewise the release flow in `build-docker.yaml` runs the workflows' commands, not the workflows, so the digest and commit checks in deploy aren't exercised there ([#2603](https://github.com/matter-labs/era-contracts/pull/2603), "What the release flow covers").

## Did the set of suites that run change?

Compare what runs before and after: `--no-match-test`/`--no-match-path`, `paths:`/`paths-ignore:`, job `if:` conditions, suites moved between jobs, coverage exclusions, deleted jobs. Each suite that stops running in a job, or in coverage, needs a stated reason and a job where it still runs.

Example: five frozen-state upgrade suites (`UpgradeTest_Local`, `UpgradeTestRecurring_Local`, `PreviousReleaseFixture` and the two emergency suites) were moved out of `test-foundry` and out of coverage ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4440341234), flagged again at [r4515092060](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4515092060)). The stated reason didn't hold, and they were restored ([r4515415360](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4515415360)).
