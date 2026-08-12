/**
 * Unit tests for the Anvil block-time resolution.
 *
 * Interval mining is what the interop suite's pacing rests on, and an invalid value fails in a
 * confusing place: a negative number used to fall through the `> 0` guard and silently switch Anvil
 * to instant mining, while Infinity was passed through to fail as an opaque process-start error.
 *
 * Run with: yarn test:block-time
 */

import * as assert from "assert/strict";
import { resolveBlockTime } from "../../src/daemons/anvil-manager";

const tests: Array<[string, () => void]> = [];
function test(name: string, fn: () => void): void {
  tests.push([name, fn]);
}

test("defaults to one second", () => {
  assert.equal(resolveBlockTime(undefined, undefined), 1);
  assert.equal(resolveBlockTime(undefined, ""), 1);
});

test("takes the environment value, including fractions anvil accepts", () => {
  assert.equal(resolveBlockTime(undefined, "0.2"), 0.2);
  assert.equal(resolveBlockTime(undefined, "2"), 2);
});

// setup-and-dump-state.ts passes 1 explicitly so chain-state generation stays deterministic.
test("an explicit argument beats the environment", () => {
  assert.equal(resolveBlockTime(1, "0.2"), 1);
  assert.equal(resolveBlockTime(0, "0.2"), 0);
});

test("allows zero, which means no interval mining", () => {
  assert.equal(resolveBlockTime(undefined, "0"), 0);
});

test("rejects negative values instead of silently changing the mining mode", () => {
  for (const bad of ["-1", "-0.5"]) {
    assert.throws(() => resolveBlockTime(undefined, bad), /finite, non-negative/, bad);
  }
  assert.throws(() => resolveBlockTime(-1), /finite, non-negative/);
});

test("rejects non-finite values rather than handing them to anvil", () => {
  for (const bad of ["Infinity", "-Infinity", "abc"]) {
    assert.throws(() => resolveBlockTime(undefined, bad), /finite, non-negative/, bad);
  }
  assert.throws(() => resolveBlockTime(Infinity), /finite, non-negative/);
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

console.log(`\n${tests.length - failed}/${tests.length} block-time tests passed`);
if (failed > 0) {
  process.exit(1);
}
