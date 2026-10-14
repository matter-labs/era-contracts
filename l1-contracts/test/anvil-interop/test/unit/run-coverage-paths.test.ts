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
import * as path from "path";
import { discoverSpecs } from "../../src/core/specs";
import { createSuite } from "./harness";
import {
  MAX_SHARDS_PER_RUN,
  PORT_OFFSET_PER_WORKER,
  RUN_PORT_SPAN,
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

/** The base of the second run, the first one a whole span away from the default run. */
const SECOND_RUN_BASE = RUN_PORT_SPAN;
const OVERLAPPING_SPAN = new RegExp(`multiple of ${RUN_PORT_SPAN}`);

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
  const second = shardsDirFor(SECOND_RUN_BASE);
  assert.notEqual(first, second);
  assert.ok(second.endsWith(`coverage/anvil/shards-p${SECOND_RUN_BASE}`));

  // A worker's directory belongs to its run's scope, not to a scope derived from its own offset:
  // shard 3 of the second run must still live under the second run's shards directory.
  const workerOffset = SECOND_RUN_BASE + 2 * PORT_OFFSET_PER_WORKER;
  const worker = shardCoverageDir(workerOffset, SECOND_RUN_BASE);
  assert.ok(worker.endsWith(`coverage/anvil/shards-p${SECOND_RUN_BASE}/p${workerOffset}`), worker);
  assert.ok(worker.startsWith(second));

  // ...and must not be mistaken for a worker of a run based at its own offset.
  assert.notEqual(shardCoverageDir(workerOffset, SECOND_RUN_BASE), shardCoverageDir(workerOffset, workerOffset));
});

test("gives every worker of a run a distinct directory", () => {
  const dirs = [0, 1, 2, 3].map((i) => shardCoverageDir(SECOND_RUN_BASE + i * PORT_OFFSET_PER_WORKER, SECOND_RUN_BASE));
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
    applyPortOffset(SECOND_RUN_BASE);
    assert.equal(process.env[key], String(SECOND_RUN_BASE));
  } finally {
    if (previous === undefined) delete process.env[key];
    else process.env[key] = previous;
  }
});

// Two runs a partial span apart share ports: base 0 and base 500 both allocate 500..900, and the
// later run's startChain kills the earlier run's Anvil processes.
test("rejects a base offset that would overlap another run", () => {
  for (const base of [PORT_OFFSET_PER_WORKER, 500, RUN_PORT_SPAN / 2, RUN_PORT_SPAN - 500]) {
    assert.throws(() => assertDisjointPortRange(base, 10), OVERLAPPING_SPAN, String(base));
  }
});

test("accepts bases a whole span apart", () => {
  for (const base of [0, RUN_PORT_SPAN, 2 * RUN_PORT_SPAN]) {
    assert.doesNotThrow(() => assertDisjointPortRange(base, 10));
  }
});

test("rejects a shard count that would outgrow its reserved range", () => {
  assert.doesNotThrow(() => assertDisjointPortRange(0, MAX_SHARDS_PER_RUN));
  assert.throws(() => assertDisjointPortRange(0, MAX_SHARDS_PER_RUN + 1), new RegExp(`only ${RUN_PORT_SPAN}`));
});

// The default local run shards every spec, so adding one must not outgrow the range unnoticed.
test("reserves enough ports to shard every spec in one run", () => {
  assert.doesNotThrow(() => assertDisjointPortRange(0, discoverSpecs(path.join(__dirname, "../hardhat")).length));
});

// Single-process runs (one spec, --serial, --fresh-deploy) wrote to the unscoped default, so two
// otherwise-disjoint runs overwrote each other's LCOV while both reported success.
test("scopes single-process output, keeping offset 0 at the default path", () => {
  assert.ok(singleRunCoverageDir(0).endsWith("coverage/anvil"));
  assert.ok(singleRunCoverageDir(SECOND_RUN_BASE).endsWith(`coverage/anvil/run-p${SECOND_RUN_BASE}`));
  assert.notEqual(singleRunCoverageDir(0), singleRunCoverageDir(SECOND_RUN_BASE));
  // ...and must not collide with a sharded run's directories.
  assert.notEqual(singleRunCoverageDir(SECOND_RUN_BASE), shardsDirFor(SECOND_RUN_BASE));
});

// A flag with no value is malformed input. Reading it as 0 also overrode an inherited safe offset,
// putting the run on the default ports and killing whatever was already there.
test("rejects --port-offset with no value", () => {
  assert.throws(() => resolvePortOffset(["--port-offset"]), /requires a value/);
  assert.throws(() => resolvePortOffset(["--html", "--port-offset"]), /requires a value/);
  // ...and must not fall back to the environment, which would mask the mistake.
  assert.throws(() => resolvePortOffset(["--port-offset"], String(SECOND_RUN_BASE)), /requires a value/);
});

// The range check was only reached in the sharded branch, so a one-spec, --serial or
// --fresh-deploy run at offset 500 still collided with shard 6 of a permitted base-0 run.
test("a single-process run needs a disjoint range too", () => {
  assert.throws(() => assertDisjointPortRange(500, 1), OVERLAPPING_SPAN);
  assert.doesNotThrow(() => assertDisjointPortRange(SECOND_RUN_BASE, 1));
});

test("scopes the HTML directory so concurrent runs cannot overwrite it", () => {
  // Derived from the same run scope as the LCOV: coverage/anvil/html vs html-p<base>.
  assert.equal(runScope(0), "");
  assert.equal(runScope(SECOND_RUN_BASE), `-p${SECOND_RUN_BASE}`);
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
