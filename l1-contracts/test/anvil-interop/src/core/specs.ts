/**
 * Which interop specs exist, and the check that every one of them ran.
 *
 * The `coverage-anvil` groups are discovered from the measured revision. `assertEverySpecRan`
 * checks what the groups report having executed rather than what the workflow meant to run.
 */

import * as fs from "fs";

/**
 * What a spec file may be called. Stricter than the discovery pattern on purpose: spec names reach a
 * shell through the workflow matrix, so a name containing a space, `;`, backtick or `$(...)` would be
 * a command-injection primitive reachable by adding a file to the repo.
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
 * Checking the workflow matrix alone would only prove what CI *meant* to run. Each group records what it
 * executed (see writeSpecsRun in run-coverage.ts) and the reporting job unions those records, so a
 * group that silently skipped a spec fails here too.
 */
export function assertEverySpecRan(specsOnDisk: string[], specsRun: string[]): void {
  const ran = new Set(specsRun);
  const missing = specsOnDisk.filter((s) => !ran.has(s));
  if (missing.length > 0) {
    throw new Error(
      `These specs exist but no coverage group ran them: ${missing.join(", ")}. ` +
        "Check coverage group discovery and execution in .github/workflows/l1-contracts-ci.yaml."
    );
  }
  const unknown = specsRun.filter((s) => !specsOnDisk.includes(s));
  if (unknown.length > 0) {
    throw new Error(
      `Coverage groups ran specs that do not exist on disk: ${unknown.join(", ")}. ` +
        "Check that all coverage groups measured the same source revision."
    );
  }
}
