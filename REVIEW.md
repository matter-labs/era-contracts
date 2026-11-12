# Review guide

Reviewers (people and agents) read this file, [`.github/REVIEW.md`](.github/REVIEW.md), and every `REVIEW.md` in a directory a change touches or one of its parents. Code rules and protocol invariants live in [`AGENTS.md`](AGENTS.md) and [`docs/ai-review/docs/`](docs/ai-review/docs/); this file does not repeat them.

There are two kinds of guidance:

- **Style rules** (this file and the area files). These are the comments reviewers kept repeating after the agents' review. Raise a break as a `nit` that names the rule, e.g. `nit: REVIEW.md#versions-are-read-not-written`. Don't argue the rule in the thread: if it is wrong, change this file.
- **What to check in build, CI and test plumbing** ([`.github/REVIEW.md`](.github/REVIEW.md)). Those are findings, not nits.

Authors and their agents: check the diff against the rules that apply before asking for review, and fix what you find.

Area rules: [`l1-contracts/deploy-scripts/`](l1-contracts/deploy-scripts/REVIEW.md), [`l1-contracts/test/`](l1-contracts/test/REVIEW.md), [`.github/workflows/`](.github/workflows/REVIEW.md).

## Versions are read, not written

Read the current protocol version from `configs/genesis/<vm>/latest.json` (or whatever the code already derives from it), never from a literal or a workflow default. Why: every literal is one more thing to bump each release, and the missed one goes stale silently.

Seen in: the upgrade test's version constant ([#2636](https://github.com/matter-labs/era-contracts/pull/2636#discussion_r4410484618), [#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268828640)), the generate workflow's version input ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444778196)).

## Dead code is deleted, not kept

When a change makes something dead, delete it in the same PR: pre-v31 interfaces, stubs for chains or ecosystems that no longer exist, dev contracts no test needs, tests whose subject is gone, and speculative logic for setups nobody runs. Storage that has to stay is renamed `__DEPRECATED_<name>`. Why: dead code is still read, reviewed and kept compiling as if it mattered.

Seen in: `IAdminPreV31` ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4269875655)), `L1MessageRootDev` ([#2561](https://github.com/matter-labs/era-contracts/pull/2561#discussion_r4229432371)), `ServerNotifierHandover.t.sol` ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444983837)), `EraStub` ([#2673](https://github.com/matter-labs/era-contracts/pull/2673#discussion_r4513494650)), settlement-layer fee logic ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4257416619)), the CTM deadline slot ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4293715628)).

## Reuse before adding

Before adding a helper, struct, errors file, test file or workflow step, look for the existing one and extend it. A helper copied into several contracts is deduplicated (a library, or one function over the differing structs). Why: copies drift, and the reviewer has to check each one.

Seen in: a helper duplicated across the upgrade registry objects ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4293876180)), a new one-error file next to an existing errors file ([#2668](https://github.com/matter-labs/era-contracts/pull/2668#discussion_r4506093392)), env loading copied between workflows ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4400876295)). Area specifics: version gates in deploy-scripts, new upgrade test files.

## Things go where the next reader looks

- Constants follow `AGENTS.md` ("Code style requirements" 1–2). In tests, ports, port offsets and versions are named constants too ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268806287), [#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4268814356)).
- A value that doesn't change between releases goes in `l1-contracts/upgrade-envs/permanent-values/`, not in each release's env ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444959126)).
- Dev, simulation and test-only code lives under a `dev`/`test` path, not beside production contracts ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4293972913)).
- An ecosystem-wide address (e.g. the interop fee manager) is stored once, in the CTM, and read from there, not added as an immutable in each consumer ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4257571186)).

Why: a reader finds a value by where values like it already are.

## Names say what the thing is now

- Rename a file or contract when its scope changes: `EmergencyUpgradeCalldata` was no longer stage-only ([#2555](https://github.com/matter-labs/era-contracts/pull/2555#discussion_r4410151474)).
- A contract that exists on one layer only carries the prefix: `L1InteropFeeManager` ([#2592](https://github.com/matter-labs/era-contracts/pull/2592#discussion_r4257712393)).
- An interface's name tells which contract implements it ([#2525](https://github.com/matter-labs/era-contracts/pull/2525#discussion_r4295057957)).

Why: a stale name makes every reader check what the thing actually does.

## Known gaps get a one-line comment

A branch that is not expected to trigger, and a known limitation that stays, each get a one-line comment saying so (the "local gotcha" `AGENTS.md` allows). Why: otherwise the next reviewer flags it, or someone "fixes" it.

Seen in: the maintenance filterer's defensive branches and the bridge cap shared by the Lido and NTV bridges ([#2668](https://github.com/matter-labs/era-contracts/pull/2668#discussion_r4506059099), [#2668](https://github.com/matter-labs/era-contracts/pull/2668#discussion_r4506172555)).

## Markdown docs

These apply to every `.md` file: `protocol-docs/`, `docs/`, and the READMEs.

- Point at another doc with a relative link, `[ecosystem upgrade](../../ecosystem-upgrade.md)`. The `{protocol-docs/<path>.md}` form is for code comments only ([#2530](https://github.com/matter-labs/era-contracts/pull/2530#discussion_r4247474693)). Why: links are clickable and the dead-links check covers them.
- Don't write the current or previous release's number. Write "the current release" and paths as `v<minor>/` or `upgrade-envs/v<major>.<minor>.<patch>-<name>/`. Numbers are fine for history ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4444791531)). Why: same as for code, they go stale at the next release.
- When a role or component goes away, remove the docs that still describe it, e.g. Guardians ([#2668](https://github.com/matter-labs/era-contracts/pull/2668#discussion_r4525548633)). Give the actual reason for a choice, not one that is merely not wrong ([#2561](https://github.com/matter-labs/era-contracts/pull/2561#discussion_r4230827763)).
