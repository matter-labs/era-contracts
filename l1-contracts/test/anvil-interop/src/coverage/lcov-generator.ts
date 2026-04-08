/**
 * Generates LCOV tracefile format from coverage data.
 *
 * LCOV format reference:
 *   TN:test_name
 *   SF:source_file_path
 *   DA:line_number,hit_count
 *   LF:lines_found (total executable lines)
 *   LH:lines_hit (lines with hit_count > 0)
 *   end_of_record
 */

import * as fs from "fs";
import * as path from "path";
import type { FunctionInfo } from "./source-map-decoder";

export interface FileCoverage {
  /** Source file path (relative to project root) */
  filePath: string;
  /** Map of line number -> hit count */
  lineHits: Map<number, number>;
  /** Set of all executable lines in this file */
  executableLines: Set<number>;
  /** Function declarations in this file with hit status */
  functions?: Array<{ qualifiedName: string; line: number; hit: boolean }>;
}

/**
 * Generates an LCOV tracefile string from coverage data.
 *
 * LCOV format:
 *   TN:test_name
 *   SF:source_file_path
 *   FN:line,name          (function declaration)
 *   FNDA:hit_count,name   (function hit data)
 *   FNF:count             (functions found)
 *   FNH:count             (functions hit)
 *   DA:line,hit_count     (line data)
 *   LF:count              (lines found)
 *   LH:count              (lines hit)
 *   end_of_record
 */
export function generateLcov(coverageData: FileCoverage[], testName = "anvil_interop"): string {
  const lines: string[] = [];

  for (const file of coverageData) {
    lines.push(`TN:${testName}`);
    lines.push(`SF:${file.filePath}`);

    // Emit FN/FNDA records if function data is available
    if (file.functions && file.functions.length > 0) {
      // FN records (sorted by line)
      const sortedFns = [...file.functions].sort((a, b) => a.line - b.line);
      for (const fn of sortedFns) {
        lines.push(`FN:${fn.line},${fn.qualifiedName}`);
      }

      // FNDA records
      for (const fn of sortedFns) {
        lines.push(`FNDA:${fn.hit ? 1 : 0},${fn.qualifiedName}`);
      }

      lines.push(`FNF:${sortedFns.length}`);
      lines.push(`FNH:${sortedFns.filter((f) => f.hit).length}`);
    }

    // Emit DA records for all executable lines
    const allLines = new Set([...file.executableLines, ...file.lineHits.keys()]);
    const sortedLines = Array.from(allLines).sort((a, b) => a - b);

    for (const line of sortedLines) {
      const hits = file.lineHits.get(line) || 0;
      lines.push(`DA:${line},${hits}`);
    }

    const linesFound = sortedLines.length;
    const linesHit = sortedLines.filter((l) => (file.lineHits.get(l) || 0) > 0).length;

    lines.push(`LF:${linesFound}`);
    lines.push(`LH:${linesHit}`);
    lines.push("end_of_record");
  }

  return lines.join("\n") + "\n";
}

/**
 * Writes LCOV data to a file.
 */
export function writeLcov(lcovContent: string, outputPath: string): void {
  const dir = path.dirname(outputPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(outputPath, lcovContent);
}

/**
 * Generates a human-readable coverage summary.
 */
export function generateSummary(coverageData: FileCoverage[]): string {
  const lines: string[] = [];

  let totalExecutable = 0;
  let totalHit = 0;

  // Sort files by path
  const sorted = [...coverageData].sort((a, b) => a.filePath.localeCompare(b.filePath));

  lines.push("Anvil Interop Coverage Summary");
  lines.push("=".repeat(60));
  lines.push("");

  // Group by top-level directory
  const groups = new Map<string, FileCoverage[]>();
  for (const file of sorted) {
    const parts = file.filePath.split("/");
    const group = parts.length > 2 ? `${parts[0]}/${parts[1]}` : parts[0];
    if (!groups.has(group)) {
      groups.set(group, []);
    }
    groups.get(group)!.push(file);
  }

  for (const [group, files] of groups) {
    let groupExec = 0;
    let groupHit = 0;

    for (const file of files) {
      const exec = file.executableLines.size || file.lineHits.size;
      const hit = Array.from(file.lineHits.values()).filter((v) => v > 0).length;
      groupExec += exec;
      groupHit += hit;
    }

    const pct = groupExec > 0 ? ((groupHit / groupExec) * 100).toFixed(1) : "N/A";
    lines.push(`${group}: ${pct}% (${groupHit}/${groupExec} lines)`);

    totalExecutable += groupExec;
    totalHit += groupHit;
  }

  lines.push("");
  lines.push("-".repeat(60));
  const overallPct = totalExecutable > 0 ? ((totalHit / totalExecutable) * 100).toFixed(1) : "N/A";
  lines.push(`TOTAL: ${overallPct}% (${totalHit}/${totalExecutable} lines)`);
  lines.push("");

  return lines.join("\n");
}

/**
 * Filters coverage data to only include relevant source files.
 * Excludes test files, dev contracts, interfaces, libraries, etc.
 */
export function filterCoverageFiles(
  coverageData: FileCoverage[],
  options?: {
    excludeTests?: boolean;
    excludeDevContracts?: boolean;
    excludeInterfaces?: boolean;
    excludeLibs?: boolean;
    /** Additional path patterns to exclude */
    excludePatterns?: RegExp[];
  }
): FileCoverage[] {
  const opts = {
    excludeTests: true,
    excludeDevContracts: true,
    excludeInterfaces: false,
    excludeLibs: true,
    excludePatterns: [],
    ...options,
  };

  return coverageData.filter((file) => {
    const p = file.filePath;

    // Must be a contracts file
    if (!p.startsWith("contracts/") && !p.includes("/contracts/")) {
      return false;
    }

    if (opts.excludeTests && (p.includes("/test/") || p.includes("Test") || p.includes("Mock"))) {
      return false;
    }

    if (opts.excludeDevContracts && p.includes("/dev-contracts/")) {
      return false;
    }

    if (opts.excludeLibs && (p.startsWith("lib/") || p.includes("/lib/"))) {
      return false;
    }

    for (const pattern of opts.excludePatterns!) {
      if (pattern.test(p)) {
        return false;
      }
    }

    // Skip files with no executable lines
    if (file.executableLines.size === 0 && file.lineHits.size === 0) {
      return false;
    }

    return true;
  });
}
