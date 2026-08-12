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

// Zero transactions is a symptom, not a valid state: the specs always transact, so it means the
// collector read the wrong chains — a stale chains.json, or an RPC the tests never used — and the
// result was an empty report that merged as "added nothing".
test("fails when no transactions were found at all", () => {
  assert.throws(
    () => assertTracesUsable({ transactions: 0, traceFailures: 0, tracedContracts: 0, hitSourceFiles: 0 }),
    /found no transactions at all[\s\S]*chains\.json/
  );
});

test("allows an empty run only when explicitly asked", () => {
  assert.doesNotThrow(() =>
    assertTracesUsable({ transactions: 0, traceFailures: 0, tracedContracts: 0, hitSourceFiles: 0, allowEmpty: true })
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
