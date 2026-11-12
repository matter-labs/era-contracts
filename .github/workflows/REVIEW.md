# Review guide: workflows

Style rules for workflow YAML, on top of the [root `REVIEW.md`](../../REVIEW.md). Raise breaks as a `nit` that names the rule. What a workflow change must be checked for (gates, scope, shared outputs) is in [`.github/REVIEW.md`](../REVIEW.md).

## Shell in YAML stays short

A `run:` block is a few commands. Anything with logic (loops, JSON parsing, resolving versions or paths) goes into a script under `scripts/` (TypeScript, like the rest of the tooling) that the step calls, and each check that stays in YAML has to decide something no later check does. Why: a script is linted, type-checked and runnable locally; YAML shell is none of these, and a reviewer can't tell which of 30 lines of checks matter.

Seen in: the image-pull step in `deploy-ecosystem-upgrade.yaml`, cut from 34 lines to 18 ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4283797678)), the upgrade-dir resolution in `generate-ecosystem-upgrade-calldata.yaml` ([#2645](https://github.com/matter-labs/era-contracts/pull/2645#discussion_r4447413036)).

## A step shared by workflows is written once

Env loading and other steps used by several workflows go into one script or a composite action under `.github/actions/`. Why: copies drift between workflows that must behave the same.

Seen in: env loading in the chain calldata workflows ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4400876295)).

## Inputs and filters stay generic

- Branch filters use globs (`draft**`, `release**`), not lists of branch names ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4396855039)).
- An environment input is a free string naming a preset, not a list that names each partner ([#2603](https://github.com/matter-labs/era-contracts/pull/2603#discussion_r4396919156)).
- A version input defaults to the current release from config (root rule).

Why: a new branch, partner or release should need no workflow edit.
