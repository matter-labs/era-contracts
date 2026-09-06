#!/usr/bin/env node
/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Runs directly in Node without installing dependencies. */

const fs = require("node:fs");

const DISPLAY_DECIMALS = 6;
const DISPLAY_SCALE = 10n ** BigInt(DISPLAY_DECIMALS);
const PERCENT = 100n;
const SHA_PATTERN = /^[0-9a-f]{40}$/i;

function parseLcov(_contents, _label = "LCOV report") {
  const totals = { covered: 0n, total: 0n };
  const sources = new Set();
  let record;
  const fail = (_message) => {
    throw new Error(`${_label}: ${_message}`);
  };

  for (const [index, line] of _contents.split(/\r?\n/).entries()) {
    if (!line) {
      continue;
    }
    if (line.startsWith("TN:") && !record) {
      continue;
    }
    if (line.startsWith("SF:")) {
      const source = line.slice(3);
      if (record || !source.trim() || sources.has(source)) {
        fail(`invalid or duplicate source record at line ${index + 1}`);
      }
      sources.add(source);
      record = { source, lines: new Set(), covered: 0n };
      continue;
    }
    if (!record) {
      fail(`expected SF: at line ${index + 1}`);
    }
    if (line === "end_of_record") {
      if (record.LF === undefined || record.LH === undefined) {
        fail(`${record.source}: missing LF or LH`);
      }
      if (record.LF !== BigInt(record.lines.size) || record.LH !== record.covered) {
        fail(`${record.source}: LF/LH do not match DA line counts`);
      }
      totals.covered += record.LH;
      totals.total += record.LF;
      record = undefined;
    } else if (line.startsWith("DA:")) {
      const match = /^DA:([0-9]+),([0-9]+)(?:,[^,\s]+)?$/.exec(line);
      if (!match || BigInt(match[1]) === 0n || record.lines.has(BigInt(match[1]))) {
        fail(`${record.source}: invalid or duplicate DA at line ${index + 1}`);
      }
      record.lines.add(BigInt(match[1]));
      if (BigInt(match[2]) > 0n) {
        record.covered++;
      }
    } else if (line.startsWith("LF:") || line.startsWith("LH:")) {
      const match = /^(LF|LH):([0-9]+)$/.exec(line);
      if (!match || record[match[1]] !== undefined) {
        fail(`${record.source}: invalid or duplicate line summary at line ${index + 1}`);
      }
      record[match[1]] = BigInt(match[2]);
    } else if (!/^(FN|FNDA|FNF|FNH|BRDA|BRF|BRH|VER|FNL|FNA):/.test(line)) {
      fail(`${record.source}: unexpected LCOV field at line ${index + 1}`);
    }
  }
  if (record) {
    fail(`${record.source}: missing end_of_record`);
  }
  if (totals.total === 0n) {
    fail("no instrumented lines");
  }
  return totals;
}

function compareCoverage(_base, _pr) {
  return _pr.covered * _base.total - _base.covered * _pr.total;
}

function formatPercentage(_numerator, _denominator) {
  const rounded = (_numerator * PERCENT * DISPLAY_SCALE + _denominator / 2n) / _denominator;
  return `${rounded / DISPLAY_SCALE}.${String(rounded % DISPLAY_SCALE).padStart(DISPLAY_DECIMALS, "0")}`;
}

function formatDelta(_difference, _denominator) {
  const magnitude = _difference < 0n ? -_difference : _difference;
  const formatted = formatPercentage(magnitude, _denominator);
  if (_difference !== 0n && Number(formatted) === 0) {
    const direction = _difference < 0n ? "decrease" : "increase";
    return `less than ${1 / Number(DISPLAY_SCALE)} percentage points ${direction}`;
  }
  const sign = _difference < 0n ? "-" : _difference > 0n ? "+" : "";
  return `${sign}${formatted} percentage points`;
}

function writeSummary(_text) {
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${_text}\n`);
  }
}

function main(_args) {
  if (_args.length !== 4 || !SHA_PATTERN.test(_args[2]) || !SHA_PATTERN.test(_args[3])) {
    throw new Error("Usage: node compare-lcov.js <base-lcov> <pr-lcov> <base-sha> <pr-sha> (full 40-character SHAs)");
  }
  const [basePath, prPath, baseSha, prSha] = _args;
  const base = parseLcov(fs.readFileSync(basePath, "utf8"), `Base report (${basePath})`);
  const pr = parseLcov(fs.readFileSync(prPath, "utf8"), `PR report (${prPath})`);
  const difference = compareCoverage(base, pr);
  const passed = difference >= 0n;
  const result = passed
    ? "Passed: total line coverage did not decrease."
    : "Failed: total line coverage decreased. Add tests to restore coverage before merging.";
  const summary = [
    "## Combined line coverage",
    "",
    "| Revision | Commit | Covered lines | Instrumented lines | Coverage |",
    "| --- | --- | ---: | ---: | ---: |",
    `| Base | \`${baseSha}\` | ${base.covered} | ${base.total} | ${formatPercentage(base.covered, base.total)}% |`,
    `| PR merge | \`${prSha}\` | ${pr.covered} | ${pr.total} | ${formatPercentage(pr.covered, pr.total)}% |`,
    "",
    `**Delta:** ${formatDelta(difference, base.total * pr.total)}.`,
    "",
    `**${result}**`,
    "",
    "Compared aggregate covered / instrumented lines using exact, unrounded ratios. Display values are rounded.",
  ].join("\n");
  console.log(summary);
  writeSummary(summary);
  return passed ? 0 : 1;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    console.error(`Coverage comparison failed: ${error.message}`);
    writeSummary(
      "## Combined line coverage\n\n**Failed: coverage could not be compared.** See the job log for details."
    );
    process.exitCode = 1;
  }
}

module.exports = { parseLcov, compareCoverage };
