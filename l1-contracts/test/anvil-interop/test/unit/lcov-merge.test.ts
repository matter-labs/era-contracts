/**
 * Unit tests for the shard LCOV union used by `run-coverage.ts`.
 *
 * Plain ts-node + node:assert: this package has no test runner of its own, and the
 * logic under test is pure string/map manipulation with no chain involved.
 *
 * Run with: yarn test:lcov-merge
 */

import * as assert from "assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { formatMergeSummary, mergeLcovFiles } from "../../src/coverage/lcov-merge";
import { createSuite } from "./harness";

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "lcov-merge-test-"));

function writeShard(name: string, content: string): string {
  const shardPath = path.join(tmpRoot, name, "anvil-lcov.info");
  fs.mkdirSync(path.dirname(shardPath), { recursive: true });
  fs.writeFileSync(shardPath, content);
  return shardPath;
}

/** Extracts the records of one SF: block as a list of lines. */
function recordFor(lcov: string, sourceFile: string): string[] {
  const blocks = lcov.split("end_of_record");
  const block = blocks.find((b) => b.includes(`SF:${sourceFile}\n`));
  assert.ok(block, `no record for ${sourceFile} in:\n${lcov}`);
  return block
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
}

const { test, run } = createSuite("lcov-merge");

// A line hit by any shard counts as hit, and the highest hit count wins. Shards
// disagree in both directions here: shard A hit line 11, shard B hit line 21, and
// both hit line 41 — that last case is what distinguishes max from a sum.
test("unions line hits across shards, taking the max", () => {
  const a = writeShard(
    "p0",
    [
      "TN:anvil_interop",
      "SF:contracts/bridge/A.sol",
      "DA:11,1",
      "DA:12,0",
      "DA:21,0",
      "DA:41,2",
      "LF:4",
      "LH:2",
      "end_of_record",
      "",
    ].join("\n")
  );
  const b = writeShard(
    "p100",
    [
      "TN:anvil_interop",
      "SF:contracts/bridge/A.sol",
      "DA:11,0",
      "DA:21,5",
      "DA:41,3",
      "LF:3",
      "LH:2",
      "end_of_record",
      "",
    ].join("\n")
  );

  const out = path.join(tmpRoot, "merged-lines.info");
  const { stats } = mergeLcovFiles([a, b], out);
  const record = recordFor(fs.readFileSync(out, "utf-8"), "contracts/bridge/A.sol");

  assert.ok(record.includes("DA:11,1"), "line 11 keeps shard A's hit");
  assert.ok(record.includes("DA:21,5"), "line 21 keeps shard B's higher hit count");
  assert.ok(record.includes("DA:41,3"), "a line both shards hit takes the max, not the sum");
  assert.ok(record.includes("DA:12,0"), "line 12 stays uncovered");
  assert.ok(record.includes("LF:4"), "LF counts the union of the line universe");
  assert.ok(record.includes("LH:3"), "LH counts lines hit by any shard");
  assert.equal(stats.lines, 4);
  assert.equal(stats.linesHit, 3);
});

// Shards resolve different contract sets, so one shard can see executable lines and
// functions the other never resolved. Those must survive the merge rather than being
// dropped or double-counted.
test("keeps lines, files and functions that only one shard resolved", () => {
  const a = writeShard(
    "only-a",
    [
      "TN:anvil_interop",
      "SF:contracts/bridge/A.sol",
      "FN:10,A.foo",
      "FNDA:1,A.foo",
      "FNF:1",
      "FNH:1",
      "DA:11,1",
      "LF:1",
      "LH:1",
      "end_of_record",
      "TN:anvil_interop",
      "SF:contracts/only-in-a/C.sol",
      "DA:6,1",
      "LF:1",
      "LH:1",
      "end_of_record",
      "",
    ].join("\n")
  );
  const b = writeShard(
    "only-b",
    [
      "TN:anvil_interop",
      "SF:contracts/bridge/A.sol",
      "FN:10,A.foo",
      "FN:30,A.qux",
      "FNDA:0,A.foo",
      "FNDA:0,A.qux",
      "FNF:2",
      "FNH:0",
      "DA:11,0",
      "DA:31,0",
      "LF:2",
      "LH:0",
      "end_of_record",
      "",
    ].join("\n")
  );

  const out = path.join(tmpRoot, "merged-union.info");
  const { stats } = mergeLcovFiles([a, b], out);
  const merged = fs.readFileSync(out, "utf-8");
  const record = recordFor(merged, "contracts/bridge/A.sol");

  assert.ok(merged.includes("SF:contracts/only-in-a/C.sol"), "a file only one shard saw is kept");
  assert.ok(record.includes("DA:31,0"), "an executable line only shard B resolved is kept, uncovered");
  assert.ok(record.includes("FN:30,A.qux"), "a function only shard B resolved is declared");
  assert.ok(record.includes("FNDA:0,A.qux"), "that function reports no hits");
  assert.ok(record.includes("FNDA:1,A.foo"), "a function hit by shard A stays hit");
  assert.ok(record.includes("FNF:2"), "FNF counts the union of declared functions");
  assert.ok(record.includes("FNH:1"), "FNH counts functions hit by any shard");
  assert.equal(stats.files, 2);
  assert.equal(stats.functions, 2);
  assert.equal(stats.functionsHit, 1);
});

// Function declarations may arrive without a matching FNDA, and hit counts must not be
// summed — a function hit 3 times by two shards is still one hit function.
test("does not sum function hit counts, and defaults undeclared hits to zero", () => {
  const a = writeShard(
    "fn-a",
    ["TN:anvil_interop", "SF:contracts/A.sol", "FN:10,A.foo", "FNDA:3,A.foo", "FN:20,A.bar", "end_of_record", ""].join(
      "\n"
    )
  );
  const b = writeShard(
    "fn-b",
    ["TN:anvil_interop", "SF:contracts/A.sol", "FN:10,A.foo", "FNDA:2,A.foo", "end_of_record", ""].join("\n")
  );

  const out = path.join(tmpRoot, "merged-fns.info");
  const { stats } = mergeLcovFiles([a, b], out);
  const record = recordFor(fs.readFileSync(out, "utf-8"), "contracts/A.sol");

  assert.ok(record.includes("FNDA:3,A.foo"), "max hit count wins, counts are not summed");
  assert.ok(record.includes("FNDA:0,A.bar"), "a function declared without FNDA reports zero");
  assert.equal(stats.functionsHit, 1);
  assert.equal(stats.functions, 2);
});

// The parent fails the run on a non-zero worker exit and on a missing shard report, so
// mergeLcovFiles only has to skip absent paths rather than invent data for them.
test("skips missing shard reports rather than failing the merge", () => {
  const a = writeShard("present", ["SF:contracts/A.sol", "DA:1,1", "end_of_record", ""].join("\n"));
  const missing = path.join(tmpRoot, "absent", "anvil-lcov.info");

  const out = path.join(tmpRoot, "merged-missing.info");
  const { stats } = mergeLcovFiles([a, missing], out);

  assert.equal(stats.files, 1);
  assert.equal(stats.linesHit, 1);
});

test("writes records sorted by source path so output is stable", () => {
  const a = writeShard(
    "sort",
    [
      "SF:contracts/z/Z.sol",
      "DA:1,1",
      "end_of_record",
      "SF:contracts/a/A.sol",
      "DA:1,1",
      "end_of_record",
      "SF:contracts/m/M.sol",
      "DA:1,0",
      "end_of_record",
      "",
    ].join("\n")
  );

  const out = path.join(tmpRoot, "merged-sorted.info");
  mergeLcovFiles([a], out);
  const order = fs
    .readFileSync(out, "utf-8")
    .split("\n")
    .filter((l) => l.startsWith("SF:"));

  assert.deepEqual(order, ["SF:contracts/a/A.sol", "SF:contracts/m/M.sol", "SF:contracts/z/Z.sol"]);
});

test("summary reports shard count and percentages", () => {
  const summary = formatMergeSummary({ files: 2, lines: 5, linesHit: 3, functions: 4, functionsHit: 3 }, 2);

  assert.match(summary, /Shards: {4}2/);
  assert.match(summary, /Lines: {5}3\/5 \(60\.00%\)/);
  assert.match(summary, /Functions: 3\/4 \(75\.00%\)/);
});

test("empty input produces an empty report rather than throwing", () => {
  const out = path.join(tmpRoot, "merged-empty.info");
  const { stats } = mergeLcovFiles([], out);

  assert.equal(stats.files, 0);
  assert.equal(fs.readFileSync(out, "utf-8").trim(), "");
});

run();

fs.rmSync(tmpRoot, { recursive: true, force: true });
