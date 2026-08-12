/**
 * Unit tests for run-coverage.ts's port-offset resolution and shard paths.
 *
 * Both exist to let coverage runs coexist, which is what ANVIL_INTEROP_PORT_OFFSET is for. Two
 * bugs here were invisible in CI, where the offset is always 0 and only one run exists: the
 * environment offset was ignored when sharding, and every run shared one shard directory that the
 * parent wipes before fanning out — so a second run deleted the first's finished reports.
 *
 * Run with: yarn test:coverage-paths
 */

import * as assert from "assert/strict";
import { resolvePortOffset, runScope, shardCoverageDir, shardsDirFor } from "../../run-coverage";

const tests: Array<[string, () => void]> = [];
function test(name: string, fn: () => void): void {
  tests.push([name, fn]);
}

test("takes the port offset from --port-offset", () => {
  assert.equal(resolvePortOffset(["--port-offset", "500"]), 500);
  assert.equal(resolvePortOffset(["--html", "--port-offset", "500", "--l1-only"]), 500);
});

// The reported bug: an exported offset was dropped, so shards went back to 0, 100, 200... and
// collided with whatever was already on the default ports.
test("falls back to the environment offset when the flag is absent", () => {
  assert.equal(resolvePortOffset([], "500"), 500);
  assert.equal(resolvePortOffset(["--html"], "700"), 700);
});

test("prefers the flag over the environment", () => {
  assert.equal(resolvePortOffset(["--port-offset", "300"], "500"), 300);
});

test("defaults to 0 with neither source", () => {
  assert.equal(resolvePortOffset([]), 0);
  assert.equal(resolvePortOffset([], ""), 0);
});

test("rejects an offset that is not a non-negative whole number", () => {
  for (const bad of ["abc", "-100", "1.5", "Infinity"]) {
    assert.throws(() => resolvePortOffset([], bad), /non-negative whole number/, bad);
    assert.throws(() => resolvePortOffset(["--port-offset", bad]), /non-negative whole number/, bad);
  }
});

test("keeps the default paths unsuffixed at offset 0, so CI and coverage:merge still match", () => {
  assert.equal(runScope(0), "");
  assert.ok(shardsDirFor(0).endsWith("coverage/anvil/shards"));
  assert.ok(shardCoverageDir(0, 0).endsWith("coverage/anvil/shards/p0"));
});

// The second reported bug: unscoped, `rmSync(shardsDir)` in one run destroys the other's reports.
test("scopes shard directories per run so concurrent runs cannot collide", () => {
  const first = shardsDirFor(0);
  const second = shardsDirFor(500);
  assert.notEqual(first, second);
  assert.ok(second.endsWith("coverage/anvil/shards-p500"));

  // A worker's directory belongs to its run's scope, not to a scope derived from its own offset:
  // shard 3 of the offset-500 run is at 700, and must still live under shards-p500.
  const worker = shardCoverageDir(700, 500);
  assert.ok(worker.endsWith("coverage/anvil/shards-p500/p700"), worker);
  assert.ok(worker.startsWith(second));

  // ...and must not be mistaken for a worker of a run based at 700.
  assert.notEqual(shardCoverageDir(700, 500), shardCoverageDir(700, 700));
});

test("gives every worker of a run a distinct directory", () => {
  const base = 500;
  const dirs = [0, 1, 2, 3].map((i) => shardCoverageDir(base + i * 100, base));
  assert.equal(new Set(dirs).size, dirs.length, dirs.join(", "));
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

console.log(`\n${tests.length - failed}/${tests.length} run-coverage-paths tests passed`);
if (failed > 0) {
  process.exit(1);
}
