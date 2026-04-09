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
 * Strategy:
 *   Foundry LCOV is the **base**: its files, executable lines, and function data
 *   define the measurement. Anvil hit counts are added only for lines that already
 *   exist in the Foundry LCOV. Anvil-only files and Anvil-only lines are excluded
 *   so the merged report has the same denominator as Foundry.
 *
 *   All non-DA records (FN, FNDA, FNF, FNH, BRDA, BRF, BRH) are preserved from
 *   the Foundry LCOV so that function and branch coverage data carry through.
 */

import * as fs from "fs";
import * as path from "path";

/** Represents a single LCOV file record with all its data. */
interface FileRecord {
  /** Raw non-DA, non-summary lines (FN, FNDA, BRDA, etc.) to preserve verbatim */
  preamble: string[];
  /** line number -> hit count */
  lines: Map<number, number>;
}

interface LcovData {
  files: Map<string, FileRecord>;
}

/**
 * Parses an LCOV file, preserving all record types.
 * DA lines are parsed into the lines map; everything else is kept as raw strings.
 */
function parseLcov(content: string): LcovData {
  const files = new Map<string, FileRecord>();
  let currentFile: string | null = null;
  let currentPreamble: string[] = [];
  let currentLines = new Map<number, number>();

  for (const line of content.split("\n")) {
    if (line.startsWith("SF:")) {
      currentFile = line.substring(3);
      currentPreamble = [];
      currentLines = new Map();
    } else if (line.startsWith("DA:") && currentFile) {
      const parts = line.substring(3).split(",");
      const lineNum = parseInt(parts[0], 10);
      const hits = parseInt(parts[1], 10);
      currentLines.set(lineNum, Math.max(currentLines.get(lineNum) || 0, hits));
    } else if (line === "end_of_record" && currentFile) {
      const existing = files.get(currentFile);
      if (existing) {
        for (const [lineNum, hits] of currentLines) {
          existing.lines.set(lineNum, Math.max(existing.lines.get(lineNum) || 0, hits));
        }
      } else {
        files.set(currentFile, { preamble: currentPreamble, lines: currentLines });
      }
      currentFile = null;
    } else if (currentFile && !line.startsWith("LF:") && !line.startsWith("LH:") && line.trim() !== "") {
      // Preserve FN, FNDA, FNF, FNH, BRDA, BRF, BRH, TN, etc.
      currentPreamble.push(line);
    }
  }

  return { files };
}

interface AnvilFileData {
  lines: Map<number, number>;
  /** function name -> hit count */
  functionHits: Map<string, number>;
}

/**
 * Parses DA and FNDA records from an LCOV file (for the secondary/Anvil input).
 */
function parseAnvilData(content: string): Map<string, AnvilFileData> {
  const files = new Map<string, AnvilFileData>();
  let currentFile: string | null = null;
  let currentLines = new Map<number, number>();
  let currentFnHits = new Map<string, number>();

  for (const line of content.split("\n")) {
    if (line.startsWith("SF:")) {
      currentFile = line.substring(3);
      currentLines = new Map();
      currentFnHits = new Map();
    } else if (line.startsWith("DA:") && currentFile) {
      const parts = line.substring(3).split(",");
      const lineNum = parseInt(parts[0], 10);
      const hits = parseInt(parts[1], 10);
      currentLines.set(lineNum, Math.max(currentLines.get(lineNum) || 0, hits));
    } else if (line.startsWith("FNDA:") && currentFile) {
      const parts = line.substring(5).split(",");
      const hits = parseInt(parts[0], 10);
      const name = parts.slice(1).join(","); // function name may not contain commas, but be safe
      currentFnHits.set(name, Math.max(currentFnHits.get(name) || 0, hits));
    } else if (line === "end_of_record" && currentFile) {
      files.set(currentFile, { lines: currentLines, functionHits: currentFnHits });
      currentFile = null;
    }
  }

  return files;
}

/**
 * Serializes merged data back to LCOV format, preserving preamble records.
 */
function toLcovString(data: LcovData): string {
  const output: string[] = [];

  const sortedFiles = Array.from(data.files.entries()).sort(([a], [b]) => a.localeCompare(b));

  for (const [file, record] of sortedFiles) {
    output.push("TN:");
    output.push(`SF:${file}`);

    // Emit preserved preamble (FN, FNDA, FNF, FNH, BRDA, BRF, BRH, etc.)
    for (const line of record.preamble) {
      // Skip any TN: lines from preamble since we emit our own
      if (!line.startsWith("TN:")) {
        output.push(line);
      }
    }

    // Emit DA lines
    const sortedLines = Array.from(record.lines.entries()).sort(([a], [b]) => a - b);
    let linesFound = 0;
    let linesHit = 0;

    for (const [lineNum, hits] of sortedLines) {
      output.push(`DA:${lineNum},${hits}`);
      linesFound++;
      if (hits > 0) linesHit++;
    }

    output.push(`LF:${linesFound}`);
    output.push(`LH:${linesHit}`);
    output.push("end_of_record");
  }

  return output.join("\n") + "\n";
}

function printSummary(label: string, fileCount: number, totalLines: number, totalHit: number): void {
  const pct = totalLines > 0 ? ((totalHit / totalLines) * 100).toFixed(1) : "N/A";
  console.log(`  ${label}: ${fileCount} files, ${totalHit}/${totalLines} lines (${pct}%)`);
}

function countLcov(data: LcovData): { files: number; lines: number; hit: number } {
  let lines = 0;
  let hit = 0;
  for (const [, record] of data.files) {
    for (const [, hits] of record.lines) {
      lines++;
      if (hits > 0) hit++;
    }
  }
  return { files: data.files.size, lines, hit };
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

// Foundry is required — it defines the measurement baseline
if (!fs.existsSync(foundryPath)) {
  console.error(`❌ Foundry LCOV not found at ${foundryPath}`);
  console.error("   Run: yarn coverage:foundry (or yarn coverage-report)");
  process.exit(1);
}

// Parse Foundry LCOV fully (preserving FN/FNDA/BRDA records)
const foundry = parseLcov(fs.readFileSync(foundryPath, "utf-8"));
const foundryStats = countLcov(foundry);
printSummary("Foundry", foundryStats.files, foundryStats.lines, foundryStats.hit);

if (!fs.existsSync(anvilPath)) {
  console.log(`  ⚠️  Anvil LCOV not found at ${anvilPath} — copying Foundry as merged output`);
  const dir = path.dirname(outputPath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(outputPath, toLcovString(foundry));
  console.log(`\n✅ Merged LCOV written to: ${outputPath}`);
  process.exit(0);
}

// Parse Anvil LCOV (DA + FNDA)
const anvilData = parseAnvilData(fs.readFileSync(anvilPath, "utf-8"));
let anvilFiles = 0;
let anvilLines = 0;
let anvilHit = 0;
for (const [, data] of anvilData) {
  anvilFiles++;
  for (const [, hits] of data.lines) {
    anvilLines++;
    if (hits > 0) anvilHit++;
  }
}
printSummary("Anvil (raw)", anvilFiles, anvilLines, anvilHit);

// --- Build rebased Anvil LCOV: Foundry's structure with only Anvil hits ---
// Deep-clone Foundry, zero all hits, then overlay Anvil hits.
const anvilRebased = parseLcov(fs.readFileSync(foundryPath, "utf-8"));
let anvilRebasedLinesHit = 0;

for (const [file, record] of anvilRebased.files) {
  const anvilFile = anvilData.get(file);

  // Zero all line hits, then set from Anvil
  for (const [lineNum] of record.lines) {
    const anvilLineHits = anvilFile?.lines.get(lineNum) || 0;
    record.lines.set(lineNum, anvilLineHits);
    if (anvilLineHits > 0) anvilRebasedLinesHit++;
  }

  // Zero all FNDA hits, then set from Anvil; recompute FNH
  let fnHitCount = 0;
  record.preamble = record.preamble.map((line) => {
    if (!line.startsWith("FNDA:")) return line;
    const parts = line.substring(5).split(",");
    const fnName = parts.slice(1).join(",");
    const anvilFnHits = anvilFile?.functionHits.get(fnName) || 0;
    if (anvilFnHits > 0) {
      fnHitCount++;
    }
    return `FNDA:${anvilFnHits},${fnName}`;
  });
  record.preamble = record.preamble.map((line) => {
    if (!line.startsWith("FNH:")) return line;
    return `FNH:${fnHitCount}`;
  });
}

const anvilRebasedStats = countLcov(anvilRebased);
printSummary("Anvil (rebased)", anvilRebasedStats.files, anvilRebasedStats.lines, anvilRebasedLinesHit);

const anvilRebasedPath = path.join(path.dirname(outputPath), "anvil-rebased-lcov.info");

// --- Build merged LCOV: Foundry hits + Anvil hits ---
let linesEnhanced = 0;
let functionsEnhanced = 0;

for (const [file, record] of foundry.files) {
  const anvilFile = anvilData.get(file);
  if (!anvilFile) continue;

  for (const [lineNum, foundryHits] of record.lines) {
    const anvilLineHits = anvilFile.lines.get(lineNum);
    if (anvilLineHits !== undefined && anvilLineHits > foundryHits) {
      record.lines.set(lineNum, anvilLineHits);
      if (foundryHits === 0) linesEnhanced++;
    }
  }

  if (anvilFile.functionHits.size > 0) {
    let fileFunctionsEnhanced = 0;
    record.preamble = record.preamble.map((line) => {
      if (!line.startsWith("FNDA:")) return line;
      const parts = line.substring(5).split(",");
      const foundryFnHits = parseInt(parts[0], 10);
      const fnName = parts.slice(1).join(",");
      const anvilFnHits = anvilFile.functionHits.get(fnName) || 0;
      if (anvilFnHits > 0 && foundryFnHits === 0) {
        fileFunctionsEnhanced++;
        return `FNDA:${anvilFnHits},${fnName}`;
      }
      if (anvilFnHits > foundryFnHits) {
        return `FNDA:${anvilFnHits},${fnName}`;
      }
      return line;
    });

    if (fileFunctionsEnhanced > 0) {
      record.preamble = record.preamble.map((line) => {
        if (!line.startsWith("FNH:")) return line;
        const currentHit = parseInt(line.substring(4), 10);
        return `FNH:${currentHit + fileFunctionsEnhanced}`;
      });
      functionsEnhanced += fileFunctionsEnhanced;
    }
  }
}

const mergedStats = countLcov(foundry);
printSummary("Merged", mergedStats.files, mergedStats.lines, mergedStats.hit);

console.log(`\n  Anvil added coverage for ${linesEnhanced} previously-uncovered lines`);
if (functionsEnhanced > 0) {
  console.log(`  Anvil added coverage for ${functionsEnhanced} previously-uncovered functions`);
}

// Write outputs
const dir = path.dirname(outputPath);
if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(outputPath, toLcovString(foundry));
fs.writeFileSync(anvilRebasedPath, toLcovString(anvilRebased));

console.log(`\n✅ Merged LCOV written to: ${outputPath}`);
console.log(`✅ Anvil (rebased) LCOV written to: ${anvilRebasedPath}`);
