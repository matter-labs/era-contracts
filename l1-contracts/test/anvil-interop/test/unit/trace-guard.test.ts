/**
 * Unit tests for the guard that refuses to write an empty coverage report.
 *
 * Per-transaction trace errors are deliberately only warnings, so one odd transaction cannot sink a
 * run. The cost is that a systemic failure — steps-tracing not enabled, an Anvil API change, the
 * wrong RPC — looks identical to "nothing was executed": an LCOV is still written, the mergers only
 * check that the file exists, and coverage-report goes green with a zero-hit Anvil contribution.
 *
 * Run with: yarn test:trace-guard
 */

import * as assert from "assert/strict";
import { assertTracesUsable } from "../../src/coverage/trace-collector";
import { assertMergedCoverageUsable } from "../../src/coverage/lcov-merge";

const tests: Array<[string, () => void]> = [];
function test(name: string, fn: () => void): void {
  tests.push([name, fn]);
}

test("accepts a healthy run", () => {
  assert.doesNotThrow(() =>
    assertTracesUsable({ transactions: 120, traceFailures: 0, tracedContracts: 53, hitSourceFiles: 28 })
  );
});

test("tolerates a few failed traces among many", () => {
  assert.doesNotThrow(() =>
    assertTracesUsable({ transactions: 120, traceFailures: 3, tracedContracts: 53, hitSourceFiles: 28 })
  );
});

// A read-only shard must not fail here. 04-gateway-setup and 01-deployment-verification assert over
// state the pre-generated snapshots already contain, so they transact nothing — an earlier version of
// this guard failed them on principle, and CI caught it. Whether a whole *run* saw nothing is the
// aggregate question, covered below.
test("accepts a shard that only read, without transacting", () => {
  assert.doesNotThrow(() =>
    assertTracesUsable({ transactions: 0, traceFailures: 0, tracedContracts: 0, hitSourceFiles: 0 })
  );
});

// The aggregate check: individual shards may contribute nothing, a whole run may not.
test("fails when no shard in the run contributed any coverage", () => {
  assert.throws(
    () => assertMergedCoverageUsable({ files: 28, lines: 2054, linesHit: 0, functions: 158, functionsHit: 0 }, 5, false),
    /No coverage from any of the 5 shard\(s\)[\s\S]*steps-tracing/
  );
});

test("accepts a run where at least one shard contributed", () => {
  assert.doesNotThrow(() =>
    assertMergedCoverageUsable({ files: 28, lines: 2054, linesHit: 545, functions: 158, functionsHit: 36 }, 5, false)
  );
});

test("allows an empty run when explicitly asked", () => {
  assert.doesNotThrow(() =>
    assertMergedCoverageUsable({ files: 0, lines: 0, linesHit: 0, functions: 0, functionsHit: 0 }, 5, true)
  );
});

// The systemic regression: tracing is off, so every call fails and the report would be empty.
test("fails when every trace call errored, and points at steps-tracing", () => {
  assert.throws(
    () => assertTracesUsable({ transactions: 120, traceFailures: 120, tracedContracts: 0, hitSourceFiles: 0 }),
    /all 120 transaction trace\(s\) errored[\s\S]*steps-tracing/
  );
});

test("fails when transactions produced no trace data at all", () => {
  assert.throws(
    () => assertTracesUsable({ transactions: 120, traceFailures: 2, tracedContracts: 0, hitSourceFiles: 0 }),
    /no trace data from 120 transaction\(s\)/
  );
});

// Traces arrived but nothing mapped to source: a source-map or artifact-resolution regression, which
// would also merge as "Anvil added 0 lines" and pass.
test("fails when traces mapped to no source lines", () => {
  assert.throws(
    () => assertTracesUsable({ transactions: 120, traceFailures: 0, tracedContracts: 53, hitSourceFiles: 0 }),
    /mapped none of them to source lines/
  );
});

let failed = 0;
for (const [name, fn] of tests) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
  } catch (error) {
    failed++;
    console.error(`  ✗ ${name}`);
    console.error(`    ${(error as Error).message}`);
  }
}

console.log(`\n${tests.length - failed}/${tests.length} trace-guard tests passed`);
if (failed > 0) {
  process.exit(1);
}
