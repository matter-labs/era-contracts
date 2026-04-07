/**
 * Merges Foundry and Anvil interop LCOV coverage reports into a single LCOV file.
 *
 * Usage:
 *   ts-node scripts/merge-coverage.ts [--foundry <path>] [--anvil <path>] [-o <output>]
 *
 * Defaults:
 *   --foundry  ./lcov.info
 *   --anvil    ./coverage/anvil/anvil-lcov.info
 *   -o         ./coverage/merged-lcov.info
 *
 * The merge takes the maximum hit count for each line when both reports
 * cover the same file, ensuring no coverage data is lost.
 */

import * as fs from "fs";
import * as path from "path";

interface LineCoverage {
  /** line number -> hit count */
  lines: Map<number, number>;
}

interface LcovData {
  files: Map<string, LineCoverage>;
}

function parseLcov(content: string): LcovData {
  const files = new Map<string, LineCoverage>();
  let currentFile: string | null = null;
  let currentLines = new Map<number, number>();

  for (const line of content.split("\n")) {
    if (line.startsWith("SF:")) {
      currentFile = line.substring(3);
      currentLines = new Map();
    } else if (line.startsWith("DA:") && currentFile) {
      const parts = line.substring(3).split(",");
      const lineNum = parseInt(parts[0], 10);
      const hits = parseInt(parts[1], 10);
      currentLines.set(lineNum, Math.max(currentLines.get(lineNum) || 0, hits));
    } else if (line === "end_of_record" && currentFile) {
      const existing = files.get(currentFile);
      if (existing) {
        // Merge into existing
        for (const [lineNum, hits] of currentLines) {
          existing.lines.set(lineNum, Math.max(existing.lines.get(lineNum) || 0, hits));
        }
      } else {
        files.set(currentFile, { lines: currentLines });
      }
      currentFile = null;
    }
  }

  return { files };
}

function mergeLcov(a: LcovData, b: LcovData): LcovData {
  const merged = new Map<string, LineCoverage>();

  // Copy all from A
  for (const [file, cov] of a.files) {
    merged.set(file, { lines: new Map(cov.lines) });
  }

  // Merge B into result
  for (const [file, cov] of b.files) {
    const existing = merged.get(file);
    if (existing) {
      for (const [lineNum, hits] of cov.lines) {
        existing.lines.set(lineNum, Math.max(existing.lines.get(lineNum) || 0, hits));
      }
    } else {
      merged.set(file, { lines: new Map(cov.lines) });
    }
  }

  return { files: merged };
}

function toLcovString(data: LcovData, testName = "merged"): string {
  const lines: string[] = [];

  const sortedFiles = Array.from(data.files.entries()).sort(([a], [b]) => a.localeCompare(b));

  for (const [file, cov] of sortedFiles) {
    lines.push(`TN:${testName}`);
    lines.push(`SF:${file}`);

    const sortedLines = Array.from(cov.lines.entries()).sort(([a], [b]) => a - b);
    let linesFound = 0;
    let linesHit = 0;

    for (const [lineNum, hits] of sortedLines) {
      lines.push(`DA:${lineNum},${hits}`);
      linesFound++;
      if (hits > 0) linesHit++;
    }

    lines.push(`LF:${linesFound}`);
    lines.push(`LH:${linesHit}`);
    lines.push("end_of_record");
  }

  return lines.join("\n") + "\n";
}

function printSummary(data: LcovData, label: string): void {
  let totalLines = 0;
  let totalHit = 0;
  let fileCount = 0;

  for (const [, cov] of data.files) {
    fileCount++;
    for (const [, hits] of cov.lines) {
      totalLines++;
      if (hits > 0) totalHit++;
    }
  }

  const pct = totalLines > 0 ? ((totalHit / totalLines) * 100).toFixed(1) : "N/A";
  console.log(`  ${label}: ${fileCount} files, ${totalHit}/${totalLines} lines (${pct}%)`);
}

// --- Main ---

const args = process.argv.slice(2);

function getArg(flag: string, defaultVal: string): string {
  const idx = args.indexOf(flag);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : defaultVal;
}

const foundryPath = getArg("--foundry", "./lcov.info");
const anvilPath = getArg("--anvil", "./coverage/anvil/anvil-lcov.info");
const outputPath = getArg("-o", "./coverage/merged-lcov.info");

console.log("📊 Coverage Merge");
console.log("=".repeat(40));

const inputs: LcovData[] = [];

if (fs.existsSync(foundryPath)) {
  const foundryData = parseLcov(fs.readFileSync(foundryPath, "utf-8"));
  printSummary(foundryData, "Foundry");
  inputs.push(foundryData);
} else {
  console.log(`  ⚠️  Foundry LCOV not found at ${foundryPath}`);
}

if (fs.existsSync(anvilPath)) {
  const anvilData = parseLcov(fs.readFileSync(anvilPath, "utf-8"));
  printSummary(anvilData, "Anvil interop");
  inputs.push(anvilData);
} else {
  console.log(`  ⚠️  Anvil LCOV not found at ${anvilPath}`);
}

if (inputs.length === 0) {
  console.error("❌ No coverage data found. Generate coverage first:");
  console.error("  yarn coverage:foundry (or yarn coverage-report)");
  console.error("  yarn coverage:anvil");
  process.exit(1);
}

if (inputs.length === 1) {
  console.log("\n  ℹ️  Only one input found. Copying as merged output.");
}

let merged = inputs[0];
for (let i = 1; i < inputs.length; i++) {
  merged = mergeLcov(merged, inputs[i]);
}

console.log("");
printSummary(merged, "Merged");

const dir = path.dirname(outputPath);
if (!fs.existsSync(dir)) {
  fs.mkdirSync(dir, { recursive: true });
}
fs.writeFileSync(outputPath, toLcovString(merged));

console.log(`\n✅ Merged LCOV written to: ${outputPath}`);
