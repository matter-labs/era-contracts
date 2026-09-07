/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Tests the Node entry point. */

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const { totals, compare } = require("./check");

const SCRIPT = path.join(__dirname, "check.js");
const BASE_SHA = "a".repeat(40);
const PR_SHA = "b".repeat(40);

function report(_hit, _found) {
  const lines = Array.from({ length: _found }, (_, _index) => `DA:${_index + 1},${Number(_index < _hit)}`);
  return ["SF:contracts/Example.sol", ...lines, `LF:${_found}`, `LH:${_hit}`, "end_of_record", ""].join("\n");
}

function run(_t, _base, _pr, _options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "coverage-check-"));
  _t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const files = [path.join(directory, "base.info"), path.join(directory, "pr.info")];
  for (const [index, contents] of [_base, _pr].entries()) {
    if (contents !== undefined) {
      fs.writeFileSync(files[index], contents);
    }
  }
  const summary = path.join(directory, "summary.md");
  fs.writeFileSync(summary, "Existing summary\n");
  const result = spawnSync(process.execPath, [SCRIPT, ...(_options.args ?? files)], {
    encoding: "utf8",
    env: { ...process.env, BASE_SHA, PR_SHA, GITHUB_STEP_SUMMARY: summary, ..._options.env },
  });
  return { ...result, summary: fs.readFileSync(summary, "utf8") };
}

test("aggregates LCOV counts instead of averaging file percentages", () => {
  assert.deepEqual(totals("LF:100\r\nLH:90\r\nLF:1\r\nLH:0\r\n"), { hit: 90n, found: 101n });
  assert.deepEqual(totals(report(0, 2)), { hit: 0n, found: 2n });
});

test("accepts equality and increases, rejects decreases including changed denominators", () => {
  const base = { hit: 90n, found: 100n };
  assert.equal(compare(base, { hit: 9n, found: 10n }), 0n);
  assert.ok(compare(base, { hit: 91n, found: 100n }) > 0n);
  assert.ok(compare(base, { hit: 90n, found: 101n }) < 0n);
  assert.ok(compare(base, { hit: 80n, found: 90n }) < 0n);
});

test("detects decreases hidden by rounding or floating-point precision", () => {
  assert.ok(compare({ hit: 80001n, found: 100000n }, { hit: 80000n, found: 100000n }) < 0n);
  const large = 10n ** 20n;
  assert.ok(compare({ hit: large, found: large }, { hit: large - 1n, found: large }) < 0n);
});

test("rejects unavailable, empty, inconsistent, and malformed line totals", () => {
  for (const contents of ["", "LF:0\nLH:0", "LF:1", "LF:1\nLH:2", "LF:2\nLH:-1", "LF:2\nLH:1.5"]) {
    assert.throws(() => totals(contents));
  }
  for (const malformed of ["LF:-1", "LH:1.5", "LH:", "LF:1junk", "LF:1:2"]) {
    assert.throws(() => totals(`${report(1, 2)}${malformed}\n`), /Invalid LCOV/);
  }
});

test("CLI accepts equal ratios and appends both identities and raw counts to the summary", (_t) => {
  const result = run(_t, report(1, 2), report(2, 4));
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.summary, /^Existing summary\n/);
  assert.match(result.summary, new RegExp(BASE_SHA));
  assert.match(result.summary, new RegExp(PR_SHA));
  assert.match(result.summary, /1 \/ 2 \| 50\.000000%/);
  assert.match(result.summary, /2 \/ 4 \| 50\.000000%/);
  assert.match(result.summary, /0\.000000 percentage points/);
  assert.match(result.summary, /Exact, unrounded ratios/);
  assert.match(result.summary, /Passed: combined line coverage did not decrease/);
});

test("CLI reports an increase and returns a distinct regression exit code", (_t) => {
  const increase = run(_t, report(1, 2), report(2, 2));
  assert.equal(increase.status, 0, increase.stderr);
  assert.match(increase.summary, /\+50\.000000 percentage points/);
  const decrease = run(_t, report(2, 2), report(1, 2));
  assert.equal(decrease.status, 1);
  assert.match(decrease.summary, /-50\.000000 percentage points/);
  assert.match(decrease.summary, /Failed: combined line coverage decreased/);
});

test("CLI rejects a decrease smaller than the display precision", (_t) => {
  const result = run(_t, report(1, 20000), report(1, 20001));
  assert.equal(result.status, 1);
  assert.match(result.summary, /less than 0\.000001 percentage points decrease/);
  assert.match(result.summary, /Failed: combined line coverage decreased/);
});

test("CLI distinguishes unavailable reports from regressions", (_t) => {
  for (const contents of [undefined, "", "LF:1\nLH:2"]) {
    for (const [base, pr, label] of [
      [contents, report(1, 2), "Baseline"],
      [report(1, 2), contents, "PR coverage"],
    ]) {
      const result = run(_t, base, pr);
      assert.equal(result.status, 2);
      assert.match(result.stderr, new RegExp(`${label} unavailable:`));
      assert.match(result.summary, /Unavailable: no regression decision was made/);
      assert.doesNotMatch(result.summary, /Passed:|Failed:/);
    }
  }
});

test("CLI requires two reports and full base and PR commit identities", (_t) => {
  for (const options of [
    { args: [] },
    { args: ["one-report"] },
    { args: ["base", "pr", "extra"] },
    { env: { BASE_SHA: "" } },
    { env: { PR_SHA: "b".repeat(7) } },
    { env: { BASE_SHA: "g".repeat(40) } },
  ]) {
    const result = run(_t, report(1, 2), report(1, 2), options);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Set BASE_SHA and PR_SHA to full commit SHAs/);
    assert.match(result.summary, /Unavailable: no regression decision was made/);
  }
});

test("CLI also works without GitHub step summaries", (_t) => {
  const result = run(_t, report(1, 2), report(1, 2), { env: { GITHUB_STEP_SUMMARY: "" } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Passed: combined line coverage did not decrease/);
  assert.equal(result.summary, "Existing summary\n");
});
