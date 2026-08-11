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
import { formatMergeSummary, mergeLcovFiles } from "./src/coverage/lcov-merge";

const LCOV_FILE_NAME = "anvil-lcov.info";

function findShardLcovs(dir: string): string[] {
  const found: string[] = [];

  const walk = (current: string): void => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        walk(entryPath);
      } else if (entry.name === LCOV_FILE_NAME) {
        found.push(entryPath);
      }
    }
  };

  walk(dir);
  // Sort so the merged output is identical regardless of directory read order.
  return found.sort();
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

const { stats } = mergeLcovFiles(shardPaths, outputPath);
const summary = formatMergeSummary(stats, shardPaths.length);
const summaryPath = path.join(path.dirname(outputPath), "anvil-coverage-summary.txt");
fs.writeFileSync(summaryPath, summary);

console.log(`\n${summary}`);
console.log(`  📄 Merged LCOV written to: ${outputPath}`);
console.log(`  📄 Summary written to: ${summaryPath}`);
