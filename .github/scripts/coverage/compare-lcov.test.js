/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Tests the dependency-free Node entry point. */

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const { parseLcov, compareCoverage } = require("./compare-lcov");

const SCRIPT = path.join(__dirname, "compare-lcov.js");
const BASE_SHA = "a".repeat(40);
const PR_SHA = "b".repeat(40);

function report(_covered, _total, _source = "contracts/Example.sol") {
  const lines = Array.from({ length: _total }, (_, _index) => `DA:${_index + 1},${_index < _covered ? 1 : 0}`);
  return ["TN:", `SF:${_source}`, ...lines, `LF:${_total}`, `LH:${_covered}`, "end_of_record", ""].join("\n");
}

function run(_t, _base, _pr, _args) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "coverage-comparison-"));
  _t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const basePath = path.join(directory, "base.info");
  const prPath = path.join(directory, "pr.info");
  const summaryPath = path.join(directory, "summary.md");
  if (_base !== undefined) {
    fs.writeFileSync(basePath, _base);
  }
  if (_pr !== undefined) {
    fs.writeFileSync(prPath, _pr);
  }
  const result = spawnSync(process.execPath, [SCRIPT, ...(_args ?? [basePath, prPath, BASE_SHA, PR_SHA])], {
    encoding: "utf8",
    env: { ...process.env, GITHUB_STEP_SUMMARY: summaryPath },
  });
  return { ...result, summary: fs.readFileSync(summaryPath, "utf8") };
}

test("aggregates line counts instead of averaging file percentages", () => {
  const largeFile = report(90, 100, "contracts/Large.sol");
  const smallFile = report(0, 1, "contracts/Small.sol");
  const totals = parseLcov(largeFile + smallFile);
  assert.deepEqual(totals, { covered: 90n, total: 101n });
  assert.ok(compareCoverage({ covered: 80n, total: 100n }, totals) > 0n);
});

test("accepts CRLF, checksums, large hit counts, and non-line coverage fields", () => {
  const contents = report(1, 2)
    .replace("DA:1,1", "FN:1,example\nFNDA:9007199254740993,example\nBRDA:1,0,0,-\nDA:1,9007199254740993,checksum")
    .replaceAll("\n", "\r\n");
  assert.deepEqual(parseLcov(contents), { covered: 1n, total: 2n });
});

test("allows empty source records when other records have instrumented lines", () => {
  assert.deepEqual(parseLcov(report(0, 0) + report(1, 1, "contracts/Other.sol")), { covered: 1n, total: 1n });
  assert.deepEqual(parseLcov(report(0, 2)), { covered: 0n, total: 2n });
});

test("compares exact ratios when covered counts and denominators change", () => {
  const base = { covered: 90n, total: 100n };
  assert.ok(compareCoverage(base, { covered: 91n, total: 100n }) > 0n);
  assert.equal(compareCoverage(base, { covered: 9n, total: 10n }), 0n);
  assert.ok(compareCoverage(base, { covered: 90n, total: 101n }) < 0n);
  assert.ok(compareCoverage(base, { covered: 80n, total: 90n }) < 0n);
  assert.ok(compareCoverage(base, { covered: 90n, total: 99n }) > 0n);
});

test("detects decreases hidden by percentage rounding and floating-point precision", () => {
  assert.ok(compareCoverage({ covered: 80001n, total: 100000n }, { covered: 80000n, total: 100000n }) < 0n);
  const total = 10n ** 20n;
  assert.ok(compareCoverage({ covered: total, total }, { covered: total - 1n, total }) < 0n);
});

const valid = report(1, 2);
const invalidReports = [
  ["empty report", "", /no instrumented lines/],
  ["no executable lines", report(0, 0), /no instrumented lines/],
  ["truncated record", valid.replace("end_of_record", ""), /missing end_of_record/],
  ["missing LF", valid.replace("LF:2\n", ""), /missing LF or LH/],
  ["missing LH", valid.replace("LH:1\n", ""), /missing LF or LH/],
  ["missing DA", valid.replace("DA:1,1\n", ""), /do not match DA/],
  ["wrong LF", valid.replace("LF:2", "LF:3"), /do not match DA/],
  ["wrong LH", valid.replace("LH:1", "LH:0"), /do not match DA/],
  ["more covered than found", valid.replace("LH:1", "LH:3"), /do not match DA/],
  ["negative count", valid.replace("LH:1", "LH:-1"), /invalid or duplicate line summary/],
  ["fractional count", valid.replace("LF:2", "LF:2.5"), /invalid or duplicate line summary/],
  ["count with trailing junk", valid.replace("LF:2", "LF:2junk"), /invalid or duplicate line summary/],
  ["duplicate summary", valid.replace("LF:2", "LF:2\nLF:2"), /invalid or duplicate line summary/],
  ["negative hits", valid.replace("DA:1,1", "DA:1,-1"), /invalid or duplicate DA/],
  ["fractional hits", valid.replace("DA:1,1", "DA:1,0.5"), /invalid or duplicate DA/],
  ["missing hits", valid.replace("DA:1,1", "DA:1,"), /invalid or duplicate DA/],
  ["zero line number", valid.replace("DA:1,1", "DA:0,1"), /invalid or duplicate DA/],
  ["duplicate line", valid.replace("DA:2,0", "DA:1,0"), /invalid or duplicate DA/],
  ["duplicate source", valid + valid, /invalid or duplicate source/],
  ["nested source", valid.replace("DA:1,1", "SF:contracts/Nested.sol\nDA:1,1"), /invalid or duplicate source/],
  ["empty source", valid.replace("SF:contracts/Example.sol", "SF:"), /invalid or duplicate source/],
  ["record without source", "LF:2\nLH:1\nend_of_record", /expected SF/],
  ["unknown field", valid.replace("DA:1,1", "garbage\nDA:1,1"), /unexpected LCOV field/],
  ["trailing garbage", valid + "garbage", /expected SF/],
];

for (const [name, contents, error] of invalidReports) {
  test(`rejects ${name}`, () => {
    assert.throws(() => parseLcov(contents, "test report"), error);
  });
}

test("CLI accepts equal coverage and writes the comparison summary", (_t) => {
  const result = run(_t, report(1, 2), report(2, 4));
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.summary, /Passed: total line coverage did not decrease/);
  assert.match(result.summary, /50\.000000%/);
  assert.match(result.summary, /\| 1 \| 2 \|/);
  assert.match(result.summary, /\| 2 \| 4 \|/);
  assert.match(result.summary, new RegExp(BASE_SHA));
  assert.match(result.summary, new RegExp(PR_SHA));
  assert.match(result.summary, /0\.000000 percentage points/);
  assert.match(result.summary, /exact, unrounded ratios/);
});

test("CLI succeeds on an increase and fails on a decrease", (_t) => {
  const increase = run(_t, report(1, 2), report(2, 2));
  assert.equal(increase.status, 0, increase.stderr);
  assert.match(increase.summary, /\+50\.000000 percentage points/);
  const decrease = run(_t, report(2, 2), report(1, 2));
  assert.equal(decrease.status, 1);
  assert.match(decrease.summary, /Failed: total line coverage decreased/);
  assert.match(decrease.summary, /-50\.000000 percentage points/);
});

test("CLI fails and explains a decrease smaller than the display precision", (_t) => {
  const result = run(_t, report(1, 20000), report(1, 20001));
  assert.equal(result.status, 1);
  assert.match(result.summary, /Failed: total line coverage decreased/);
  assert.match(result.summary, /less than 0\.000001 percentage points decrease/);
});

test("CLI rejects missing or invalid report data and writes a failure summary", (_t) => {
  for (const contents of [undefined, "", valid.replace("LH:1", "LH:2")]) {
    const result = run(_t, contents, valid);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Coverage comparison failed:/);
    assert.match(result.summary, /Failed: coverage could not be compared/);
    assert.doesNotMatch(result.summary, /Passed/);
  }
  const result = run(_t, valid, undefined);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /ENOENT/);
});

test("CLI rejects invalid argument counts and abbreviated or malformed SHAs", (_t) => {
  for (const args of [
    [],
    ["base", "pr"],
    ["base", "pr", "a".repeat(7), PR_SHA],
    ["base", "pr", BASE_SHA, "g".repeat(40)],
  ]) {
    const result = run(_t, valid, valid, args);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Usage: node compare-lcov\.js/);
    assert.match(result.summary, /Failed: coverage could not be compared/);
  }
});
