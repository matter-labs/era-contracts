/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Runs directly in Node. */

const fs = require("node:fs");

function totals(_lcov) {
  // The producer validates the full LCOV report before publishing it.
  const fields = (_name) =>
    _lcov
      .split(/\r?\n/)
      .filter((_line) => _line.startsWith(`${_name}:`))
      .map((_line) => {
        const value = _line.slice(3);
        if (!/^\d+$/.test(value)) {
          throw new Error(`Invalid LCOV ${_name} count`);
        }
        return BigInt(value);
      });
  const hit = fields("LH");
  const found = fields("LF");
  if (!hit.length || hit.length !== found.length || hit.some((_n, _i) => _n > found[_i])) {
    throw new Error("Missing or inconsistent LCOV line totals");
  }
  const sum = (_values) => _values.reduce((_a, _b) => _a + _b, 0n);
  const result = { hit: sum(hit), found: sum(found) };
  if (result.found === 0n) {
    throw new Error("LCOV report has no instrumented lines");
  }
  return result;
}

function compare(_base, _pr) {
  return _pr.hit * _base.found - _base.hit * _pr.found;
}

function readReport(_file, _label) {
  try {
    return totals(fs.readFileSync(_file, "utf8"));
  } catch (error) {
    throw new Error(`${_label} unavailable: ${error.message}`);
  }
}

function writeSummary(_text) {
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${_text}\n`);
  }
}

function main() {
  const results = JSON.parse(process.env.COVERAGE_RESULTS || "{}");
  const failed = Object.entries(results)
    .filter(([, _job]) => _job.result !== "success")
    .map(([_name]) => _name);
  if (failed.length) {
    throw new Error(`${failed.join(", ")} did not succeed. Rerun the failed jobs to retry baseline recovery.`);
  }
  if (process.env.COVERAGE_INPUTS_READY === "false") {
    throw new Error("Coverage setup or artifact download did not succeed. Rerun the failed jobs to retry.");
  }
  const { BASE_SHA: baseSha, PR_SHA: prSha } = process.env;
  if (process.argv.length !== 4 || ![baseSha, prSha].every((_sha) => /^[a-f0-9]{40}$/i.test(_sha || ""))) {
    throw new Error("Set BASE_SHA and PR_SHA to full commit SHAs, then run check.js <base-lcov> <pr-lcov>");
  }
  const base = readReport(process.argv[2], "Baseline");
  const current = readReport(process.argv[3], "PR coverage");
  const difference = compare(base, current);
  const percent = (_counts) => ((100 * Number(_counts.hit)) / Number(_counts.found)).toFixed(4);
  const delta = (100 * Number(difference)) / Number(base.found * current.found);
  const result =
    difference < 0n ? "Failed: combined line coverage decreased." : "Passed: combined line coverage did not decrease.";
  const summary = `## Coverage comparison

| Revision | Commit | Covered / total lines | Coverage |
| --- | --- | ---: | ---: |
| Base | \`${baseSha}\` | ${base.hit} / ${base.found} | ${percent(base)}% |
| PR merge | \`${prSha}\` | ${current.hit} / ${current.found} | ${percent(current)}% |

Delta: ${delta.toPrecision(4)} percentage points. Exact, unrounded ratios determine the result.

**${result}**

Each revision uses its own test and coverage code. Review changes to measurement logic alongside this comparison.`;
  console.log(summary);
  writeSummary(summary);
  process.exitCode = difference < 0n ? 1 : 0;
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`Coverage comparison unavailable: ${error.message}`);
    writeSummary(`## Coverage comparison\n\n**Unavailable: no regression decision was made.** ${error.message}`);
    process.exitCode = 2;
  }
}

module.exports = { totals, compare };
