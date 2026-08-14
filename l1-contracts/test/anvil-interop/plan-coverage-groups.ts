#!/usr/bin/env node

/**
 * Spec discovery and the completeness guard for the `coverage-anvil` matrix.
 *
 * The matrix itself is written out in `l1-contracts-ci.yaml` — two groups of five — because a
 * generated one bought nothing: the job that produced it ran alongside `build` and cost no wall
 * clock, but the balance it computed could not help either. The groups sit within 5% of each other
 * (354s vs 337s) while `coverage-foundry` at 383s dominates both, so rebalancing cannot move the
 * stage until the foundry gate comes down. Splitting into more groups is worse still: measured, one
 * spec per runner reached ~7.0m of wall clock for ~43 runner-minutes, against ~7.5m for ~14.
 *
 * What a hardcoded matrix cannot do by itself is notice a spec that exists but is in no group — it
 * would simply never run, with every job green. `assertEverySpecRan` is that check, and it works
 * from what the groups report having executed rather than from the workflow file.
 */

import * as fs from "fs";

/**
 * What a spec file may be called. Stricter than the discovery pattern on purpose: these names are
 * emitted space-separated into a workflow matrix and expanded by a shell, so a name containing a
 * space, `;`, backtick or `$(...)` would be a command-injection primitive reachable by adding a file
 * to the repo. Nothing legitimate needs those characters.
 */
const SAFE_SPEC_NAME = /^\d+[0-9A-Za-z._-]*\.spec\.ts$/;

export function discoverSpecs(specDir: string): string[] {
  const candidates = fs
    .readdirSync(specDir)
    .filter((f) => /^\d+-.*\.spec\.ts$/.test(f))
    .sort();

  // Rejected loudly rather than filtered out: silently skipping a spec would drop a test from
  // coverage while every job still went green, which is the failure this planner exists to prevent.
  const unsafe = candidates.filter((f) => !SAFE_SPEC_NAME.test(f));
  if (unsafe.length > 0) {
    throw new Error(
      `Spec file name(s) unsafe for shell expansion: ${unsafe.map((f) => JSON.stringify(f)).join(", ")}. ` +
        "Spec names must match digits followed by letters, digits, dots, underscores or hyphens."
    );
  }

  return candidates;
}

/**
 * Fails unless the specs that actually ran are exactly the specs on disk.
 *
 * The CI matrix is a hardcoded list of groups, which is cheap and readable but has one dangerous
 * failure: a spec added to the repo and not to the workflow never runs, and nothing goes red. This is
 * the check for it, and it is deliberately not a check on the workflow file — comparing a parsed
 * matrix against the filesystem would only prove what CI *meant* to run. Each group records what it
 * executed (see writeSpecsRun in run-coverage.ts) and the reporting job unions those records, so a
 * group that silently skipped a spec fails here too.
 */
export function assertEverySpecRan(specsOnDisk: string[], specsRun: string[]): void {
  const ran = new Set(specsRun);
  const missing = specsOnDisk.filter((s) => !ran.has(s));
  if (missing.length > 0) {
    throw new Error(
      `These specs exist but no coverage group ran them: ${missing.join(", ")}. ` +
        "Add them to one of the `group` lists in .github/workflows/l1-contracts-ci.yaml."
    );
  }
  const unknown = specsRun.filter((s) => !specsOnDisk.includes(s));
  if (unknown.length > 0) {
    throw new Error(
      `Coverage groups ran specs that do not exist on disk: ${unknown.join(", ")}. ` +
        "A spec was renamed or removed without updating the matrix."
    );
  }
}
