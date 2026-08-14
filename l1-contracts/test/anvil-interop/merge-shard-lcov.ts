#!/usr/bin/env node

/**
 * Unions the per-shard Anvil LCOV reports produced by separate CI jobs.
 *
 * The `coverage-anvil` matrix runs one spec per runner and uploads that runner's
 * `anvil-lcov.info` as its own artifact. The reporting job downloads them all into
 * one directory tree and calls this script to union them into the single report that
 * `yarn coverage:merge` consumes.
 *
 * In-process sharding (`run-coverage.ts` without `--spec`) unions its own shards and
 * does not need this script.
 *
 * Usage:
 *   ts-node merge-shard-lcov.ts <input-dir> [-o <output-lcov>]
 *
 * Defaults:
 *   -o  ../../coverage/anvil/anvil-lcov.info
 */

import * as fs from "fs";
import * as path from "path";
import { assertMergedCoverageUsable, formatMergeSummary, mergeLcovFiles } from "./src/coverage/lcov-merge";
import { assertEverySpecRan, discoverSpecs } from "./plan-coverage-groups";

const LCOV_FILE_NAME = "anvil-lcov.info";
const SPECS_RUN_PATTERN = /^specs-run.*\.json$/;

function findFiles(dir: string, matches: (name: string) => boolean): string[] {
  const found: string[] = [];

  const walk = (current: string): void => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        walk(entryPath);
      } else if (matches(entry.name)) {
        found.push(entryPath);
      }
    }
  };

  walk(dir);
  // Sort so the merged output is identical regardless of directory read order.
  return found.sort();
}

const findShardLcovs = (dir: string): string[] => findFiles(dir, (name) => name === LCOV_FILE_NAME);

/** The union of what every group reported running, from the records they upload beside their LCOV. */
function specsActuallyRun(dir: string): string[] {
  const records = findFiles(dir, (name) => SPECS_RUN_PATTERN.test(name));
  if (records.length === 0) {
    throw new Error(
      `No specs-run.json found under ${dir}. Each coverage group uploads one beside its LCOV; ` +
        "without them there is no evidence that every spec ran."
    );
  }

  const specs = new Set<string>();
  for (const record of records) {
    const parsed = JSON.parse(fs.readFileSync(record, "utf8"));
    if (!Array.isArray(parsed?.specs)) {
      throw new Error(`${record} has no "specs" array`);
    }
    for (const spec of parsed.specs) specs.add(spec);
  }
  return [...specs].sort();
}

function getArg(flag: string, defaultValue: string): string {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 && process.argv[idx + 1] ? process.argv[idx + 1] : defaultValue;
}

const inputDir = process.argv[2];
if (!inputDir || inputDir.startsWith("-")) {
  console.error("Usage: ts-node merge-shard-lcov.ts <input-dir> [-o <output-lcov>]");
  process.exit(1);
}

if (!fs.existsSync(inputDir)) {
  console.error(`❌ Shard directory not found: ${inputDir}`);
  process.exit(1);
}

const outputPath = path.resolve(getArg("-o", path.join(__dirname, "../../coverage/anvil", LCOV_FILE_NAME)));

const shardPaths = findShardLcovs(inputDir);

// Every matrix job must contribute a report. Merging an empty set would quietly
// produce a 0%-Anvil report and let a broken shard pass as "no extra coverage".
if (shardPaths.length === 0) {
  console.error(`❌ No ${LCOV_FILE_NAME} found under ${inputDir}`);
  process.exit(1);
}

console.log(`📊 Merging ${shardPaths.length} shard LCOV report(s) from ${inputDir}`);
for (const shardPath of shardPaths) {
  console.log(`   ${path.relative(inputDir, shardPath)}`);
}

// Before merging numbers, check the population they came from. The matrix in l1-contracts-ci.yaml
// lists its groups by hand, so a spec added to the repo and not to the matrix would simply never
// run — every job green, that spec's coverage silently gone. This compares what the groups report
// having run against the specs on disk, which is evidence of execution rather than of intent.
const specsRun = specsActuallyRun(inputDir);
const specsOnDisk = discoverSpecs(path.join(__dirname, "test/hardhat"));
assertEverySpecRan(specsOnDisk, specsRun);
console.log(`✅ All ${specsOnDisk.length} specs were run by some group`);

const { stats } = mergeLcovFiles(shardPaths, outputPath);

// The same check the in-process path runs. Without it this command — the one `coverage-report`
// uses — accepted shard reports that existed but contained no hits at all, which is exactly the
// silent "covered nothing" outcome the guard exists to prevent.
assertMergedCoverageUsable(stats, shardPaths.length);

const summary = formatMergeSummary(stats, shardPaths.length);
const summaryPath = path.join(path.dirname(outputPath), "anvil-coverage-summary.txt");
fs.writeFileSync(summaryPath, summary);

console.log(`\n${summary}`);
console.log(`  📄 Merged LCOV written to: ${outputPath}`);
console.log(`  📄 Summary written to: ${summaryPath}`);
