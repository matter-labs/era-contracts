# Review guide

Reviewers (people and agents) read this whole file. Each section after the first is headed by the paths it applies to; skip the ones a change doesn't touch. Code rules and protocol invariants live in [`AGENTS.md`](AGENTS.md) and [`docs/ai-review/docs/`](docs/ai-review/docs/); this file does not repeat them.

There are two kinds of guidance:

- **Style rules** (the first four sections). These are the comments reviewers kept repeating after the agents' review. Raise a break as a `nit` that names the rule, e.g. `nit: REVIEW.md#versions-are-read-not-written`. Don't argue the rule in the thread: if it is wrong, change this file.
- **What to check** (the last two sections: build, CI and test plumbing, and contract state). These came from real bugs caught in review. Raise each break as a `should-fix`, or a `blocker` when it would let a broken release, upgrade or contract through; never as a `nit`, so the review isn't clean until it is fixed. Raise them in every round, including in code a fix round added.

Authors and their agents: check the diff against the sections that apply before asking for review, and fix what you find.

## Style rules: every file

### Versions are read, not written

Read the current protocol version from `configs/genesis/<vm>/latest.json` (or whatever the code already derives from it), never from a literal or a workflow default. Why: every literal is one more thing to bump each release, and the missed one goes stale silently.

Seen in: the upgrade test's version constant ([#2636](https://github.com/matter-labs/era-contracts/pull/2636#discussion_r4410484618), [#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268828640)), the generate workflow's version input ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444778196)).

### Dead code is deleted, not kept

When a change makes something dead, delete it in the same PR: pre-v31 interfaces, stubs for chains or ecosystems that no longer exist, dev contracts no test needs, tests whose subject is gone, and speculative logic for setups nobody runs. Storage that has to stay is renamed `__DEPRECATED_<name>`. Why: dead code is still read, reviewed and kept compiling as if it mattered.

Seen in: `IAdminPreV31` ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4269875655)), `ServerNotifierHandover.t.sol` ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444983837)), `EraStub` ([#2673](https://github.com/matter-labs/era-contracts/pull/2673#discussion_r4513494650)) and settlement-layer fee logic ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4257416619)).

### Reuse before adding

Before adding a helper, struct, errors file, test file or workflow step, look for the existing one and extend it. A helper copied into several contracts is deduplicated (a library, or one function over the differing structs). Why: copies drift, and the reviewer has to check each one.

Seen in: a helper duplicated across the upgrade registry objects ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4293876180)), a new one-error file next to an existing errors file ([#2668](https://github.com/matter-labs/era-contracts/pull/2668#discussion_r4506093392)), env loading copied between workflows ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4400876295)). Area specifics: version gates in deploy-scripts, new upgrade test files.

### Things go where the next reader looks

- Constants follow [`AGENTS.md`](AGENTS.md#code-style-requirements) ("Code style requirements" 1–2), in tests too: the EIP-1967 slot goes in the harness's `const.ts`, not in the helper that reads it ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268806287)). Ports and port offsets are named constants ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268814356)).
- A value that doesn't change between releases goes in `l1-contracts/upgrade-envs/permanent-values/`, not in each release's env ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444959126)).
- Dev, simulation and test-only code lives under a `dev`/`test` path, not beside production contracts ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4293972913)).
- An ecosystem-wide address (e.g. the interop fee manager) is stored once, in the CTM, and read from there, not added as an immutable in each consumer ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4257571186)).

Why: a reader finds a value by where values like it already are.

### Names say what the thing is now

- Rename a file or contract when its scope changes: `EmergencyUpgradeCalldata` was no longer stage-only ([#2555](https://github.com/matter-labs/era-contracts/pull/2555#discussion_r4410151474)).
- A contract that exists on one layer only carries the prefix: `L1InteropFeeManager` ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4257712393)).
- An interface's name tells which contract implements it ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4295057957)).

Why: a stale name makes every reader check what the thing actually does.

### Known gaps get a one-line comment

A branch that is not expected to trigger, and a known limitation that stays, each get a one-line comment saying so (the "local gotcha" [`AGENTS.md`](AGENTS.md#documentation-and-comments) allows). Why: otherwise the next reviewer flags it, or someone "fixes" it.

Seen in: the maintenance filterer's defensive branches and the bridge cap shared by the Lido and NTV bridges ([#2668](https://github.com/matter-labs/era-contracts/pull/2668#discussion_r4506059099), [#2668](https://github.com/matter-labs/era-contracts/pull/2668#discussion_r4506172555)).

### Markdown docs

These apply to every `.md` file: `protocol-docs/`, `docs/`, and the READMEs.

- Point at another doc with a relative link, `[ecosystem upgrade](../../ecosystem-upgrade.md)`. The brace pointer form that [`AGENTS.md`](AGENTS.md#single-source-of-truth-protocol-docs) prescribes is for code comments only ([#2530](https://github.com/matter-labs/era-contracts/pull/2530#discussion_r4247474693)). Why: links are clickable and the dead-links check covers them.
- Don't write the current or previous release's number. Write "the current release" and paths as `v<minor>/` or `upgrade-envs/v<major>.<minor>.<patch>-<name>/`. Numbers are fine for history ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444791531)). Why: same as for code, they go stale at the next release.
- When a role or component goes away, remove the docs that still describe it, e.g. Guardians ([#2668](https://github.com/matter-labs/era-contracts/pull/2668#discussion_r4525548633)). Give the actual reason for a choice, not one that is merely not wrong ([#2561](https://github.com/matter-labs/era-contracts/pull/2561#discussion_r4230827763)).

## Style rules: `l1-contracts/deploy-scripts/`

### Version-specific steps go in that version's scripts

A step only one release needs goes in `upgrade/v<minor>/`, not in `upgrade/default-upgrade/`, even behind a version guard. Why: the default upgrade is what every later release inherits, so a guarded one-off stays in it forever.

Seen in: a v35-only deploy step in `DefaultCTMUpgrade` ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268739960)).

### Version gates use `ProtocolVersionFeatures`

To ask "does this version have X", use `utils/ProtocolVersionFeatures.sol` (on the release branches), and add the feature there if it is missing. Don't compare versions inline. Why: one table of when each contract or feature arrived is checked once; inline comparisons are checked at every call site.

Seen in: `AddressIntrospector` ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4294007216), [#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268766656)).

### Address structs are extended, not multiplied

A new deployed address goes into the existing struct for its layer (e.g. `StateTransitionDeployedAddresses` in `utils/Types.sol`). Retire a near-duplicate struct instead of adding another. Why: two structs for the same addresses must be kept in sync by hand.

Seen in: `L1SpecificStateTransitionAddresses` ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268788288)).

### Manual operator steps belong in the scripts

If a runbook tells the operator to run a step by hand that the upgrade scripts could do, make it part of the scripts. Why: a manual step is skipped or done differently on some environment.

Seen in: the proxy-admin split step in `docs/upgrade-operations.md` ([#2673](https://github.com/matter-labs/era-contracts/pull/2673#discussion_r4513102266)).

## Style rules: `l1-contracts/test/`

These come on top of the "Testing Guidelines" in [`AGENTS.md`](AGENTS.md). Changes to test harnesses, fixtures and foundry profiles also get the [build, CI and test checks](#what-to-check-workflows-packagejson-foundrytoml-dockerfiles-harnesses-fixtures).

### Upgrade tests follow the current release

Upgrade tests read the release they upgrade to from config (`configs/genesis/<vm>/latest.json` and what derives from it), with no version constant to bump. Why: a test pinned to the last release keeps passing while it no longer tests the next one.

Seen in: `UpgradeTest_Local` ([#2636](https://github.com/matter-labs/era-contracts/pull/2636#discussion_r4410484618), [#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268828640)).

### A new upgrade case extends the existing integration test

Add an upgrade scenario to the shared upgrade integration test (`UpgradeTest_Local` and its shared base) rather than a new `UpgradeTest*_Local` file with its own setup. Why: each copy of the setup drifts from the real flow, and the real flow is the one that ships.

Seen in: `UpgradeTestSplitProxyAdmin_Local` ([#2673](https://github.com/matter-labs/era-contracts/pull/2673#discussion_r4513497848)).

### Tests whose subject is gone are deleted

When the code or release a test covers is gone, delete the test, or the half of it that no longer applies. Don't keep it green with stubs. Why: it costs CI time and suggests coverage that isn't there.

Seen in: `ServerNotifierHandover.t.sol` ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444983837)), `EraStub` ([#2673](https://github.com/matter-labs/era-contracts/pull/2673#discussion_r4513494650)).

## Style rules: `.github/workflows/`

### Shell in YAML stays short

A `run:` block is a few commands. Anything with logic (loops, JSON parsing, resolving versions or paths) goes into a script under `scripts/` (TypeScript, like the rest of the tooling) that the step calls, and each check that stays in YAML has to decide something no later check does. Why: a script is linted, type-checked and runnable locally; YAML shell is none of these, and a reviewer can't tell which of 30 lines of checks matter.

Seen in: the image-pull step in `deploy-ecosystem-upgrade.yaml`, cut from 34 lines to 18 ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4283797678)), the upgrade-dir resolution in `generate-ecosystem-upgrade-calldata.yaml` ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4447413036)).

### A step shared by workflows is written once

Env loading and other steps used by several workflows go into one script or a composite action under `.github/actions/`. Why: copies drift between workflows that must behave the same.

Seen in: env loading in the chain calldata workflows ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4400876295)).

### Inputs and filters stay generic

- Branch filters use globs (`draft**`, `release**`), not lists of branch names ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4396855039)).
- An environment input is a free string naming a preset, not a list that names each partner ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4396919156)).
- A version input defaults to the current release from config ([versions are read](#versions-are-read-not-written)).

Why: a new branch, partner or release should need no workflow edit.

## What to check: workflows, `package.json`, `foundry*.toml`, Dockerfiles, harnesses, fixtures

For changes to workflows, `package.json` scripts, `foundry*.toml` profiles, Dockerfiles, test harnesses or fixtures. Breaks here are silent: a gate that can't fail looks like a gate that passes, so per-PR CI won't catch them. Raise breaks as `should-fix` or `blocker`, as the top of this file says. For getting CI green see [`docs/ai-review/docs/ci-green.md`](docs/ai-review/docs/ci-green.md).

### What does the gate actually verify?

For every gate a change adds or edits, name an input that turns it red. It should fail when the thing it guards is false (the run passed, on this commit, from the right source), not only when an input is malformed. A green run of a new gate proves nothing; ask how it was seen to fail.

Example: the release gate in `build-docker.yaml` took a zksync-os-integration-tests run URL and checked only its format. It now requires that the run passed and that its `Cargo.lock` pins era-contracts at the commit being built ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4396866664)).

### Do two builds or steps share an output or cache directory?

A profile, build or step that writes different artifacts to the same `out/`, cache, `script-out/` or fixture directory as another one means the last writer wins, and later readers can't tell. A foundry profile that changes bytecode (metadata, optimizer, compiler settings) gets its own `out` and `cache_path`. Check every reader of the shared directory, not only the step that wrote it.

Example: the `anvil-interop` profile (no CBOR metadata) built into the default profile's `out/` and `cache-forge`. After a previous-release test run, `copy-to-zkstack-out`, the hashes, the selectors and the anvil harness read metadata-off bytecode ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4442412494), `l1-contracts/package.json`).

### Is each side of a comparison built like production?

A test that compares two builds made the same non-production way passes on any difference that only production sees. Name the production check the test stands in for, and confirm the test feeds it the same kind of input.

Example: the upgrade tests compared metadata-off builds on both sides, while the real prepare compares full code hashes. A metadata-only change (one new constant in `Config.sol` changed 94 of 97 hashes on #2592) would pass every per-PR check and fail first at the stage calldata prepare ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4442412499), `PreviousReleaseFixture.sol`). The fix was a per-PR test that runs the prepare's reuse check against the previous release's frozen `AllContractsHashes.json`.

### Does a changed test still test what its name says?

When a test loses setup, stages or assertions, read its name, its suite and the PR description against what is left. Either restore the check or say in the PR what is no longer covered.

Example: with the bootstrap stages gone, `yarn test:upgrade` stopped sending an interop message after the upgrade, so the upgrade test no longer showed that interop works afterwards ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4515415086)). Likewise the release flow in `build-docker.yaml` runs the workflows' commands, not the workflows, so the digest and commit checks in deploy aren't exercised there ([#2603](https://github.com/matter-labs/era-contracts/pull/2603), "What the release flow covers").

### Did the set of suites that run change?

Compare what runs before and after: `--no-match-test`/`--no-match-path`, `paths:`/`paths-ignore:`, job `if:` conditions, suites moved between jobs, coverage exclusions, deleted jobs. Each suite that stops running in a job, or in coverage, needs a stated reason and a job where it still runs.

Example: five frozen-state upgrade suites (`UpgradeTest_Local`, `UpgradeTestRecurring_Local`, `PreviousReleaseFixture` and the two emergency suites) were moved out of `test-foundry` and out of coverage ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4440341234), flagged again at [r4515092060](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4515092060)). The stated reason didn't hold, and they were restored ([r4515415360](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4515415360)).

## What to check: `l1-contracts/contracts/` state and access

When a change adds privileged setters, caps, counters or feature switches, check each of these. Raise breaks as `should-fix` or `blocker`, as the top of this file says. The set-once and prerequisite checks are exceptions to the "trusted governance" false positive in [`general.md`](docs/ai-review/docs/general.md#common-false-positives): governance runs backfills and switches one call at a time, so the contract enforces how often and in which order.

### Can a one-time setter be called again?

A backfill, migration or seeding function that writes accounting state (balances, caps, limits, counters) is set-once: it reverts once the value is set or the step is done, unless the PR says why it must stay callable. Why: otherwise the owner can overwrite live state and step around the invariants the state enforces.

Seen in: the chain-balance backfill in `L1NativeTokenVault` ([#2601](https://github.com/matter-labs/era-contracts/pull/2601#discussion_r4285805308)).

### Is every path into a cap counted on both sides?

When a change adds a cap or a tracked balance to a shared flow (bridge, vault, message root), list every path that reaches it (native and interop-moved assets, each origin and destination chain combination) and check that each path's inflow and outflow are counted the same way. Why: a path counted on one side only reverts at the cap later, on withdrawal.

Seen in: assets whose origin and chain both have interop enabled, in `L1NativeTokenVault` ([#2601](https://github.com/matter-labs/era-contracts/pull/2601#discussion_r4285824641)).

### Does enabling check its prerequisite?

A per-chain or per-asset switch that depends on an earlier step (a backfill, migration or initialization) reverts on-chain while that step isn't done. Why: governance running steps in the wrong order should fail, not half-enable a feature.

Seen in: `enableInterop` before the chain's backfill, in `L1MessageRoot` ([#2601](https://github.com/matter-labs/era-contracts/pull/2601#discussion_r4323644135)).

### Is a security requirement enforced at every entry point?

When a change adds a requirement that guards security-critical state (a second proof system, a whitelist, a gating flag), find every path that can change that state (the upgrade contract, the CTM, the admin upgrade path, chain creation) and check that each one enforces it. Why: a check in one path is dropped by the next upgrade or skipped by a path that doesn't go through it.

Seen in: the second-proof-system requirement, checked in `BaseZkSyncUpgrade` but not in the CTM ([#2601](https://github.com/matter-labs/era-contracts/pull/2601#discussion_r4285902207)).
