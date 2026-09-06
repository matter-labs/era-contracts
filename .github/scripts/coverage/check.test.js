/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Tests the Node entry point. */

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { totals, compare, mergedPr, checkoutSha } = require("./check");

test("aggregates LCOV counts instead of averaging file percentages", () => {
  assert.deepEqual(totals("LF:100\r\nLH:90\r\nLF:1\r\nLH:0\r\n"), { hit: 90n, found: 101n });
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

test("rejects unavailable, empty or inconsistent line totals", () => {
  for (const report of ["", "LF:0\nLH:0", "LF:1", "LF:1\nLH:2", "LF:2\nLH:-1", "LF:2\nLH:1.5"]) {
    assert.throws(() => totals(report));
  }
});

test("selects only the merged PR that produced the exact base commit", () => {
  const expected = { number: 3, merged_at: "2026-09-04", merge_commit_sha: "base" };
  const candidates = [
    { number: 1, merged_at: null, merge_commit_sha: "base" },
    { number: 2, merged_at: "2026-09-04", merge_commit_sha: "other" },
    expected,
  ];
  assert.equal(mergedPr(candidates, "base"), expected);
  assert.throws(() => mergedPr(candidates, "missing"), /baseline is unavailable/);
});

test("reads the tested merge SHA from historical checkout logs and rejects missing evidence", () => {
  const sha = "45b8f0821b074c9399b62c6e3cbd977e323d71d8";
  const log = `2026-09-04T12:32:13Z [command]/usr/bin/git log -1 --format=%H\n2026-09-04T12:32:13Z ${sha}\n`;
  assert.equal(checkoutSha(log), sha);
  assert.equal(checkoutSha(log.replaceAll("\n", "\r\n")), sha);
  assert.throws(() => checkoutSha(`2026-09-04T12:32:13Z ${sha}\n`), /Cannot identify/);
});
