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
import { createSuite } from "./harness";
import {
  applyPortOffset,
  shouldShardRun,
  assertDisjointPortRange,
  resolvePortOffset,
  runScope,
  shardCoverageDir,
  shardsDirFor,
  singleRunCoverageDir,
} from "../../run-coverage";

const { test, run } = createSuite("run-coverage-paths");

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
  const second = shardsDirFor(1000);
  assert.notEqual(first, second);
  assert.ok(second.endsWith("coverage/anvil/shards-p1000"));

  // A worker's directory belongs to its run's scope, not to a scope derived from its own offset:
  // shard 3 of the offset-1000 run is at 1200, and must still live under shards-p1000.
  const worker = shardCoverageDir(1200, 1000);
  assert.ok(worker.endsWith("coverage/anvil/shards-p1000/p1200"), worker);
  assert.ok(worker.startsWith(second));

  // ...and must not be mistaken for a worker of a run based at 1200.
  assert.notEqual(shardCoverageDir(1200, 1000), shardCoverageDir(1200, 1200));
});

test("gives every worker of a run a distinct directory", () => {
  const base = 1000;
  const dirs = [0, 1, 2, 3].map((i) => shardCoverageDir(base + i * 100, base));
  assert.equal(new Set(dirs).size, dirs.length, dirs.join(", "));
});

// The flag is documented to beat the environment, and a guard on truthiness meant `--port-offset 0`
// left an inherited non-zero offset in place, so the chains came up on the inherited ports.
test("an explicit zero offset overrides a non-zero environment value", () => {
  const key = "ANVIL_INTEROP_PORT_OFFSET";
  const previous = process.env[key];
  try {
    process.env[key] = "500";
    const resolved = resolvePortOffset(["--port-offset", "0"], process.env[key]);
    assert.equal(resolved, 0);
    applyPortOffset(resolved);
    assert.equal(process.env[key], "0", "the environment must reflect the resolved offset");
  } finally {
    if (previous === undefined) delete process.env[key];
    else process.env[key] = previous;
  }
});

test("applyPortOffset publishes any resolved offset, including non-zero", () => {
  const key = "ANVIL_INTEROP_PORT_OFFSET";
  const previous = process.env[key];
  try {
    applyPortOffset(1000);
    assert.equal(process.env[key], "1000");
  } finally {
    if (previous === undefined) delete process.env[key];
    else process.env[key] = previous;
  }
});

// Two runs a partial span apart share ports: base 0 and base 500 both allocate 500..900, and the
// later run's startChain kills the earlier run's Anvil processes.
test("rejects a base offset that would overlap another run", () => {
  for (const base of [100, 500, 900, 1500]) {
    assert.throws(() => assertDisjointPortRange(base, 10), /multiple of 1000/, String(base));
  }
});

test("accepts bases a whole span apart", () => {
  for (const base of [0, 1000, 2000]) {
    assert.doesNotThrow(() => assertDisjointPortRange(base, 10));
  }
});

test("rejects a shard count that would outgrow its reserved range", () => {
  assert.doesNotThrow(() => assertDisjointPortRange(0, 10));
  assert.throws(() => assertDisjointPortRange(0, 11), /reserves\s+only 1000|only 1000/);
});

// Single-process runs (one spec, --serial, --fresh-deploy) wrote to the unscoped default, so two
// otherwise-disjoint runs overwrote each other's LCOV while both reported success.
test("scopes single-process output, keeping offset 0 at the default path", () => {
  assert.ok(singleRunCoverageDir(0).endsWith("coverage/anvil"));
  assert.ok(singleRunCoverageDir(1000).endsWith("coverage/anvil/run-p1000"));
  assert.notEqual(singleRunCoverageDir(0), singleRunCoverageDir(1000));
  // ...and must not collide with a sharded run's directories.
  assert.notEqual(singleRunCoverageDir(1000), shardsDirFor(1000));
});

// A flag with no value is malformed input. Reading it as 0 also overrode an inherited safe offset,
// putting the run on the default ports and killing whatever was already there.
test("rejects --port-offset with no value", () => {
  assert.throws(() => resolvePortOffset(["--port-offset"]), /requires a value/);
  assert.throws(() => resolvePortOffset(["--html", "--port-offset"]), /requires a value/);
  // ...and must not fall back to the environment, which would mask the mistake.
  assert.throws(() => resolvePortOffset(["--port-offset"], "1000"), /requires a value/);
});

// The range check was only reached in the sharded branch, so a one-spec, --serial or
// --fresh-deploy run at offset 500 still collided with shard 6 of a permitted base-0 run.
test("a single-process run needs a disjoint range too", () => {
  assert.throws(() => assertDisjointPortRange(500, 1), /multiple of 1000/);
  assert.doesNotThrow(() => assertDisjointPortRange(1000, 1));
});

test("scopes the HTML directory so concurrent runs cannot overwrite it", () => {
  // Derived from the same run scope as the LCOV: coverage/anvil/html vs html-p1000.
  assert.equal(runScope(0), "");
  assert.equal(runScope(1000), "-p1000");
});

// Without snapshots each worker does its own full deployment, so sharding would run them
// concurrently against one shared config/permanent-values.toml and broadcast directory.
test("does not shard when chain-state snapshots are missing", () => {
  const base = { workerMode: false, serial: false, freshDeploy: false, specCount: 10 };
  assert.equal(shouldShardRun({ ...base, snapshotsAvailable: true }), true);
  assert.equal(shouldShardRun({ ...base, snapshotsAvailable: false }), false);
});

test("does not shard for a fresh deploy, --serial, a worker, or a single spec", () => {
  const base = { workerMode: false, serial: false, freshDeploy: false, snapshotsAvailable: true, specCount: 10 };
  assert.equal(shouldShardRun(base), true);
  assert.equal(shouldShardRun({ ...base, freshDeploy: true }), false);
  assert.equal(shouldShardRun({ ...base, serial: true }), false);
  assert.equal(shouldShardRun({ ...base, workerMode: true }), false);
  assert.equal(shouldShardRun({ ...base, specCount: 1 }), false);
});

run();
