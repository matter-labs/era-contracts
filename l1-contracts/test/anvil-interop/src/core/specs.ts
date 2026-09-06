/**
 * Which interop specs exist, and the check that every one of them ran.
 *
 * CI partitions the specs discovered in each checkout across coverage groups. `assertEverySpecRan`
 * checks what those groups actually executed, so a group that silently skips a spec cannot pass.
 */

import * as fs from "fs";

/**
 * What a spec file may be called. Stricter than the discovery pattern on purpose: spec names reach a
 * shell argument list, so names must be safe to split on whitespace.
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
 * Each group records its executed specs through writeSpecsRun in run-coverage.ts. The reporting
 * job unions those records, independently of the selection that assigned specs to groups.
 */
export function assertEverySpecRan(specsOnDisk: string[], specsRun: string[]): void {
  const ran = new Set(specsRun);
  const missing = specsOnDisk.filter((s) => !ran.has(s));
  if (missing.length > 0) {
    throw new Error(
      `These specs exist but no coverage group ran them: ${missing.join(", ")}. ` +
        "Check the spec selection in .github/workflows/l1-contracts-ci.yaml and the group logs."
    );
  }
  const unknown = specsRun.filter((s) => !specsOnDisk.includes(s));
  if (unknown.length > 0) {
    throw new Error(
      `Coverage groups ran specs that do not exist on disk: ${unknown.join(", ")}. ` +
        "Check that the coverage groups and reporting job used the same revision."
    );
  }
}
