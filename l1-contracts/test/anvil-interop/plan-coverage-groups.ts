#!/usr/bin/env node

/**
 * Packs the interop specs into a fixed number of balanced groups and prints the result as
 * JSON, for the `coverage-anvil` matrix in `l1-contracts-ci.yaml` to consume.
 *
 * Why groups rather than one job per spec: a runner costs the same whether it uses one core
 * or four, so parallelising *inside* a job is free while adding jobs is not. Measured on
 * run 31402819829 (one spec per runner): ~113s of fixed setup per job and 1456s of total
 * spec work, with the longest single spec at 272s. That puts the wall-clock floor at about
 * 385s no matter how wide the fan-out goes, so:
 *
 *   groups   leg wall clock   runner time
 *   1        ~10.7m           ~10.7m       (measured, in-process sharding at cap 4)
 *   2        ~7.5m            ~14m
 *   10       ~7.0m            ~43m         (measured, one spec per runner)
 *
 * Two groups buy nearly all of the speedup for a third of the runner minutes; going wider
 * spends ~29 extra runner-minutes to save well under a minute of wall clock.
 *
 * Each group runs through `run-coverage.ts`'s in-process sharding, so its specs still run
 * concurrently within the job.
 *
 * Usage:
 *   ts-node plan-coverage-groups.ts [--groups N]
 */

import * as fs from "fs";
import * as path from "path";

/** How many matrix jobs to fan out into. See the table above before changing this. */
const DEFAULT_GROUP_COUNT = 2;

/**
 * Per-spec cost in seconds, measured solo on a dedicated runner (run 31402819829).
 *
 * This is a scheduling hint only: a stale or missing entry costs balance, never coverage.
 * Specs absent from this table are treated as the most expensive known spec, so a new spec
 * is scheduled first rather than tacked onto an already-full group. To refresh, read the
 * "Run Anvil interop coverage" step durations off a `coverage-anvil` matrix run.
 */
const SPEC_COST_SECONDS: Record<string, number> = {
  "01-deployment-verification": 21,
  "02-direct-bridge": 118,
  "03-interop-transfer": 135,
  "04-gateway-setup": 21,
  "05-gateway-bridge": 128,
  "06-gateway-interop": 126,
  "07-interop-bundles": 269,
  "08-interop-messages": 190,
  "09-interop-unbundle": 272,
  "13-imt-atomic-swap": 176,
};

export interface SpecGroup {
  /** Stable label. Job names derive from this, so renaming changes required-check names. */
  name: string;
  /** Spec file names (not paths), space-separated for the workflow to expand. */
  specs: string;
}

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

export function costOf(specFile: string): number {
  const key = specFile.replace(/\.spec\.ts$/, "");
  const known = SPEC_COST_SECONDS[key];
  if (known !== undefined) return known;
  return Math.max(...Object.values(SPEC_COST_SECONDS));
}

/**
 * Longest-processing-time-first packing: sort by descending cost, then repeatedly assign the
 * next spec to the cheapest group. Good enough here — the schedule only needs to avoid
 * stacking the two long specs on one runner.
 */
export function planGroups(specs: string[], groupCount: number): SpecGroup[] {
  if (groupCount < 1) {
    throw new Error(`groupCount must be at least 1, got ${groupCount}`);
  }

  const count = Math.min(groupCount, specs.length);
  const buckets: Array<{ specs: string[]; cost: number }> = Array.from({ length: count }, () => ({
    specs: [],
    cost: 0,
  }));

  // Sort by cost descending, breaking ties by name so the plan is deterministic.
  const ordered = [...specs].sort((a, b) => costOf(b) - costOf(a) || a.localeCompare(b));

  for (const spec of ordered) {
    let cheapest = buckets[0];
    for (const bucket of buckets) {
      if (bucket.cost < cheapest.cost) cheapest = bucket;
    }
    cheapest.specs.push(spec);
    cheapest.cost += costOf(spec);
  }

  return buckets.map((bucket, index) => ({
    name: `group-${index + 1}`,
    // Keep each group's specs in file order for readable logs.
    specs: bucket.specs.sort().join(" "),
  }));
}

/** Throws unless every discovered spec lands in exactly one group. */
export function assertCoversAllSpecs(specs: string[], groups: SpecGroup[]): void {
  const assigned = groups.flatMap((g) => (g.specs === "" ? [] : g.specs.split(" ")));
  const duplicates = assigned.filter((s, i) => assigned.indexOf(s) !== i);
  if (duplicates.length > 0) {
    throw new Error(`Spec assigned to more than one group: ${duplicates.join(", ")}`);
  }
  const missing = specs.filter((s) => !assigned.includes(s));
  if (missing.length > 0) {
    throw new Error(`Spec missing from every group: ${missing.join(", ")}`);
  }
  const unknown = assigned.filter((s) => !specs.includes(s));
  if (unknown.length > 0) {
    throw new Error(`Group references a spec that does not exist: ${unknown.join(", ")}`);
  }
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
        "Add them to the `group` matrix in .github/workflows/l1-contracts-ci.yaml " +
        "(`yarn plan:groups` prints a balanced assignment)."
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

function main(): void {
  const args = process.argv.slice(2);
  const idx = args.indexOf("--groups");
  const groupCount = idx !== -1 ? parseInt(args[idx + 1], 10) : DEFAULT_GROUP_COUNT;
  if (Number.isNaN(groupCount)) {
    throw new Error("--groups requires a number");
  }

  const specDir = path.join(__dirname, "test/hardhat");
  const specs = discoverSpecs(specDir);
  if (specs.length === 0) {
    throw new Error(`No interop spec files found in ${specDir}`);
  }

  const groups = planGroups(specs, groupCount);
  assertCoversAllSpecs(specs, groups);

  for (const group of groups) {
    const cost = group.specs.split(" ").reduce((sum, s) => sum + costOf(s), 0);
    console.error(`  ${group.name}: ~${cost}s of spec work — ${group.specs}`);
  }
  console.log(JSON.stringify(groups));
}

// Only run when invoked directly, so the unit test can import the helpers.
if (require.main === module) {
  main();
}
