import * as fs from "fs";

/**
 * This script parses an lcov.info file and generates a report of untested lines.
 * Usage: ts-node scripts/generate-untested-lines-report.ts [lcov-file-path] [output-file-path]
 *
 * If no arguments provided, uses defaults:
 * - lcov file: ./lcov.info
 * - output file: ./UNTESTED_LINES_REPORT.md
 */

interface FileInfo {
  path: string;
  totalLines: number;
  coveredLines: number;
  untestedLines: number[];
  coveragePercent: number;
}

interface ParsedLcov {
  files: Map<string, FileInfo>;
}

function parseLcov(lcovContent: string): ParsedLcov {
  const files = new Map<string, FileInfo>();
  let currentFile: FileInfo | null = null;

  const lines = lcovContent.split("\n");

  for (const line of lines) {
    if (line.startsWith("SF:")) {
      // Source file
      const filePath = line.substring(3);
      currentFile = {
        path: filePath,
        totalLines: 0,
        coveredLines: 0,
        untestedLines: [],
        coveragePercent: 0,
      };
    } else if (line.startsWith("DA:") && currentFile) {
      // Data line: DA:line_number,hit_count
      const parts = line.substring(3).split(",");
      const lineNumber = parseInt(parts[0], 10);
      const hitCount = parseInt(parts[1], 10);

      if (hitCount === 0) {
        currentFile.untestedLines.push(lineNumber);
      }
    } else if (line.startsWith("LF:") && currentFile) {
      // Lines Found (total executable lines)
      currentFile.totalLines = parseInt(line.substring(3), 10);
    } else if (line.startsWith("LH:") && currentFile) {
      // Lines Hit (covered lines)
      currentFile.coveredLines = parseInt(line.substring(3), 10);
    } else if (line === "end_of_record" && currentFile) {
      // End of file record
      if (currentFile.totalLines > 0) {
        currentFile.coveragePercent = (currentFile.coveredLines / currentFile.totalLines) * 100;
        files.set(currentFile.path, currentFile);
      }
      currentFile = null;
    }
  }

  return { files };
}

function generateReport(parsed: ParsedLcov, outputPath: string): void {
  const fileInfos = Array.from(parsed.files.values());

  // Filter to contract files only (matching forge coverage calculation)
  // Also exclude L2-only contracts that cannot be tested with L1 tests
  const contractFiles = fileInfos.filter(
    (f) =>
      (f.path.includes("/contracts/") || f.path.startsWith("contracts/")) &&
      !f.path.includes("/test/") &&
      !f.path.includes("/dev-contracts/") &&
      !f.path.includes("Mock") &&
      !f.path.includes("Test") &&
      // Exclude L2-only contracts (cannot be tested with L1 foundry tests)
      !f.path.includes("L2NativeTokenVault") &&
      !f.path.includes("L2AssetRouter") &&
      !f.path.includes("L2AssetTracker") &&
      !f.path.includes("L2Bridgehub") &&
      !f.path.includes("L2SharedBridgeLegacy") &&
      !f.path.includes("L2ChainAssetHandler") &&
      !f.path.includes("L2MessageRoot") &&
      !f.path.includes("L2WrappedBaseToken") &&
      !f.path.includes("InteropCenter") &&
      !f.path.includes("InteropHandler") &&
      !f.path.includes("/l2-upgrades/") &&
      !f.path.includes("/l2-system/")
  );

  // Filter to only files with untested lines for detailed reporting
  const filesWithUntestedLines = contractFiles.filter((f) => f.untestedLines.length > 0);

  // Sort by number of untested lines (descending)
  filesWithUntestedLines.sort((a, b) => b.untestedLines.length - a.untestedLines.length);

  // Generate markdown report
  const lines: string[] = [];
  lines.push("# Untested Lines Report");
  lines.push("");
  lines.push(`Generated at: ${new Date().toISOString()}`);
  lines.push("");
  lines.push("This report shows all source code files with untested lines,");
  lines.push("sorted by number of untested lines (highest first).");
  lines.push("");
  lines.push("## Summary");
  lines.push("");

  // Calculate overall coverage from contract files (matching forge coverage behavior)
  const totalLines = contractFiles.reduce((sum, f) => sum + f.totalLines, 0);
  const totalCovered = contractFiles.reduce((sum, f) => sum + f.coveredLines, 0);
  const totalUntested = filesWithUntestedLines.reduce((sum, f) => sum + f.untestedLines.length, 0);
  const overallCoverage = totalLines > 0 ? (totalCovered / totalLines) * 100 : 0;

  lines.push(`- **Total files with untested code:** ${filesWithUntestedLines.length}`);
  lines.push(`- **Total untested lines:** ${totalUntested}`);
  lines.push(`- **Total executable lines:** ${totalLines}`);
  lines.push(`- **Overall line coverage:** ${overallCoverage.toFixed(2)}%`);
  lines.push("");
  lines.push("## Files with Untested Lines");
  lines.push("");

  // Table header
  lines.push("| File | Coverage | Untested Lines | Specific Lines |");
  lines.push("|------|----------|----------------|----------------|");

  for (const file of filesWithUntestedLines) {
    // Simplify path for display
    const displayPath = file.path.replace(/^.*\/contracts\//, "contracts/");

    // Format untested lines as ranges where possible
    const lineRanges = formatLineRanges(file.untestedLines);

    // Truncate line ranges if too long
    const maxRangeLength = 300;
    const truncatedRanges =
      lineRanges.length > maxRangeLength ? lineRanges.substring(0, maxRangeLength) + "..." : lineRanges;

    lines.push(
      `| ${displayPath} | ${file.coveragePercent.toFixed(1)}% | ${file.untestedLines.length} | ${truncatedRanges} |`
    );
  }

  lines.push("");
  lines.push("## Detailed Untested Lines by File");
  lines.push("");

  for (const file of filesWithUntestedLines.slice(0, 30)) {
    // Top 30 files
    const displayPath = file.path.replace(/^.*\/contracts\//, "contracts/");
    lines.push(`### ${displayPath}`);
    lines.push("");
    lines.push(`- Coverage: ${file.coveragePercent.toFixed(2)}%`);
    lines.push(`- Total lines: ${file.totalLines}`);
    lines.push(`- Covered lines: ${file.coveredLines}`);
    lines.push(`- Untested lines (${file.untestedLines.length}): ${formatLineRanges(file.untestedLines)}`);
    lines.push("");
  }

  if (filesWithUntestedLines.length > 30) {
    lines.push(`... and ${filesWithUntestedLines.length - 30} more files with untested code.`);
    lines.push("");
  }

  // Write report
  fs.writeFileSync(outputPath, lines.join("\n"));
  console.log(`Report generated: ${outputPath}`);
}

function formatLineRanges(lineNumbers: number[]): string {
  if (lineNumbers.length === 0) return "";

  const sorted = [...lineNumbers].sort((a, b) => a - b);
  const ranges: string[] = [];
  let rangeStart = sorted[0];
  let rangeEnd = sorted[0];

  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i] === rangeEnd + 1) {
      rangeEnd = sorted[i];
    } else {
      ranges.push(rangeStart === rangeEnd ? `${rangeStart}` : `${rangeStart}-${rangeEnd}`);
      rangeStart = sorted[i];
      rangeEnd = sorted[i];
    }
  }
  ranges.push(rangeStart === rangeEnd ? `${rangeStart}` : `${rangeStart}-${rangeEnd}`);

  return ranges.join(", ");
}

// Main execution
const args = process.argv.slice(2);
const lcovPath = args[0] || "./lcov.info";
const outputPath = args[1] || "./UNTESTED_LINES_REPORT.md";

if (!fs.existsSync(lcovPath)) {
  console.error(`Error: lcov file not found at ${lcovPath}`);
  console.error("");
  console.error("Please run coverage first:");
  console.error("  yarn coverage-report");
  console.error("");
  console.error("Or specify a different lcov file:");
  console.error("  ts-node scripts/generate-untested-lines-report.ts <lcov-file> [output-file]");
  process.exit(1);
}

console.log(`Reading lcov from: ${lcovPath}`);
const lcovContent = fs.readFileSync(lcovPath, "utf-8");

console.log("Parsing lcov data...");
const parsed = parseLcov(lcovContent);

console.log(`Found ${parsed.files.size} files in lcov data`);
generateReport(parsed, outputPath);
