/**
 * Unions several Anvil LCOV tracefiles into one.
 *
 * Used to combine the per-shard reports produced by parallel `run-coverage.ts`
 * workers into the single `coverage/anvil/anvil-lcov.info` that
 * `scripts/merge-coverage.ts` consumes.
 *
 * A shard only resolves the addresses its own specs touched, so file and line sets differ between
 * shards: the union takes the whole line universe and the max hit count per line and per function —
 * a line was covered if any shard hit it. The union denominator only affects the standalone "Anvil
 * (raw)" summary, since merge-coverage.ts rebases hits onto Foundry's.
 */

import * as fs from "fs";
import * as path from "path";

/** LCOV `TN:` record; matches what lcov-generator.ts emits so both reports read alike. */
const TEST_NAME = "anvil_interop";

interface FileRecord {
  /** line number -> max hit count across shards */
  lines: Map<number, number>;
  /** function qualified name -> declaration line */
  functionLines: Map<string, number>;
  /** function qualified name -> max hit count across shards */
  functionHits: Map<string, number>;
}

export interface MergeStats {
  files: number;
  lines: number;
  linesHit: number;
  functions: number;
  functionsHit: number;
}

function parseInto(content: string, files: Map<string, FileRecord>): void {
  let current: FileRecord | null = null;

  for (const rawLine of content.split("\n")) {
    const line = rawLine.trim();

    if (line.startsWith("SF:")) {
      const filePath = line.substring(3);
      let record = files.get(filePath);
      if (!record) {
        record = { lines: new Map(), functionLines: new Map(), functionHits: new Map() };
        files.set(filePath, record);
      }
      current = record;
    } else if (!current) {
      continue;
    } else if (line.startsWith("DA:")) {
      const [lineNumRaw, hitsRaw] = line.substring(3).split(",");
      const lineNum = parseInt(lineNumRaw, 10);
      const hits = parseInt(hitsRaw, 10);
      if (!Number.isNaN(lineNum) && !Number.isNaN(hits)) {
        current.lines.set(lineNum, Math.max(current.lines.get(lineNum) ?? 0, hits));
      }
    } else if (line.startsWith("FN:")) {
      const parts = line.substring(3).split(",");
      const declLine = parseInt(parts[0], 10);
      const name = parts.slice(1).join(",");
      if (name && !Number.isNaN(declLine)) {
        current.functionLines.set(name, declLine);
        // Ensure every declared function has an entry, so a function declared in
        // one shard but never hit in any still shows up as FNDA:0.
        if (!current.functionHits.has(name)) {
          current.functionHits.set(name, 0);
        }
      }
    } else if (line.startsWith("FNDA:")) {
      const parts = line.substring(5).split(",");
      const hits = parseInt(parts[0], 10);
      const name = parts.slice(1).join(",");
      if (name && !Number.isNaN(hits)) {
        current.functionHits.set(name, Math.max(current.functionHits.get(name) ?? 0, hits));
      }
    } else if (line === "end_of_record") {
      current = null;
    }
  }
}

function serialize(files: Map<string, FileRecord>, testName: string): { content: string; stats: MergeStats } {
  const output: string[] = [];
  const stats: MergeStats = { files: 0, lines: 0, linesHit: 0, functions: 0, functionsHit: 0 };

  const sortedFiles = Array.from(files.entries()).sort(([a], [b]) => a.localeCompare(b));

  for (const [filePath, record] of sortedFiles) {
    stats.files++;
    output.push(`TN:${testName}`);
    output.push(`SF:${filePath}`);

    const sortedFns = Array.from(record.functionLines.entries()).sort(([, a], [, b]) => a - b);
    for (const [name, declLine] of sortedFns) {
      output.push(`FN:${declLine},${name}`);
    }
    let functionsHit = 0;
    for (const [name] of sortedFns) {
      const hits = record.functionHits.get(name) ?? 0;
      if (hits > 0) functionsHit++;
      output.push(`FNDA:${hits},${name}`);
    }
    if (sortedFns.length > 0) {
      output.push(`FNF:${sortedFns.length}`);
      output.push(`FNH:${functionsHit}`);
    }
    stats.functions += sortedFns.length;
    stats.functionsHit += functionsHit;

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

    stats.lines += linesFound;
    stats.linesHit += linesHit;
  }

  return { content: output.join("\n") + "\n", stats };
}

/**
 * Reads every given LCOV path and writes their union to `outputPath`.
 *
 * Missing paths are skipped (a shard that produced no report is reported by the
 * caller, which fails the run on a non-zero worker exit before we get here).
 */
export function mergeLcovFiles(inputPaths: string[], outputPath: string): { stats: MergeStats } {
  const files = new Map<string, FileRecord>();

  for (const inputPath of inputPaths) {
    if (!fs.existsSync(inputPath)) continue;
    parseInto(fs.readFileSync(inputPath, "utf-8"), files);
  }

  const { content, stats } = serialize(files, TEST_NAME);

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, content);

  return { stats };
}

/**
 * Fails when a whole run produced no coverage at all — the aggregate level is the right one, since
 * individual specs may legitimately only read (01, 04), but every shard contributing nothing means
 * the collector saw the wrong chains or tracing was off, which otherwise merges as "added 0 lines".
 */
export function assertMergedCoverageUsable(
  stats: MergeStats,
  shardCount: number,
  allowEmpty = process.env.ANVIL_INTEROP_ALLOW_EMPTY_COVERAGE === "1"
): void {
  if (stats.linesHit > 0) return;

  if (allowEmpty) {
    console.warn("  ⚠️  No coverage from any shard; continuing because ANVIL_INTEROP_ALLOW_EMPTY_COVERAGE is set.");
    return;
  }

  throw new Error(
    `No coverage from any of the ${shardCount} shard(s): ${stats.lines} line(s) known, none hit. ` +
      "Individual specs can be read-only, but a whole run with nothing hit usually means the " +
      "collector read the wrong chains (a stale outputs/state*/chains.json, or an RPC the tests did " +
      "not use) or that Anvil ran without --steps-tracing. Set ANVIL_INTEROP_ALLOW_EMPTY_COVERAGE=1 " +
      "if an empty run is genuinely expected."
  );
}

/** Renders the same shape of summary that `lcov-generator.generateSummary` produces. */
export function formatMergeSummary(stats: MergeStats, shardCount: number): string {
  const linePct = stats.lines > 0 ? ((stats.linesHit / stats.lines) * 100).toFixed(2) : "0.00";
  const fnPct = stats.functions > 0 ? ((stats.functionsHit / stats.functions) * 100).toFixed(2) : "0.00";

  return [
    "Anvil Interop Coverage Summary (merged across shards)",
    "=".repeat(52),
    `Shards:    ${shardCount}`,
    `Files:     ${stats.files}`,
    `Lines:     ${stats.linesHit}/${stats.lines} (${linePct}%)`,
    `Functions: ${stats.functionsHit}/${stats.functions} (${fnPct}%)`,
    "",
  ].join("\n");
}
