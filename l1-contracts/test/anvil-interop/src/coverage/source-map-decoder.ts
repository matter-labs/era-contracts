/**
 * Decodes Solidity source maps from Forge compilation artifacts.
 *
 * Source maps use a compressed format where each instruction maps to a source location:
 *   s:l:f:j:m  (start, length, fileIndex, jumpType, modifierDepth)
 * Empty fields inherit from the previous entry. Entries are separated by ';'.
 *
 * We combine these with the build-info source_id_to_path mapping to resolve
 * program counter (PC) values to source file paths and line numbers.
 */

import * as fs from "fs";
import * as path from "path";

export interface SourceLocation {
  /** Source file path relative to the project root */
  file: string;
  /** 1-based line number */
  line: number;
  /** Byte offset in source */
  start: number;
  /** Length in bytes */
  length: number;
  /** Source file index from compiler */
  fileIndex: number;
}

interface SourceMapEntry {
  start: number;
  length: number;
  fileIndex: number;
  jump: string;
}

/** Maps source file index to relative path */
export type SourceIdMap = Record<string, string>;

/**
 * Loads the source_id_to_path mapping from the Forge build-info directory.
 */
export function loadSourceIdMap(outDir: string): SourceIdMap {
  const buildInfoDir = path.join(outDir, "build-info");
  if (!fs.existsSync(buildInfoDir)) {
    throw new Error(`Build info directory not found: ${buildInfoDir}`);
  }

  const files = fs.readdirSync(buildInfoDir).filter((f) => f.endsWith(".json"));
  if (files.length === 0) {
    throw new Error(`No build-info JSON files found in ${buildInfoDir}`);
  }

  // Use the first (and typically only) build-info file
  const buildInfo = JSON.parse(fs.readFileSync(path.join(buildInfoDir, files[0]), "utf-8"));
  return buildInfo.source_id_to_path || {};
}

/**
 * Parses a compressed Solidity source map string into an array of entries,
 * one per instruction (not per byte — each entry corresponds to one EVM opcode).
 */
function parseSourceMap(sourceMap: string): SourceMapEntry[] {
  const entries: SourceMapEntry[] = [];
  const parts = sourceMap.split(";");

  let prev: SourceMapEntry = { start: 0, length: 0, fileIndex: -1, jump: "-" };

  for (const part of parts) {
    const fields = part.split(":");
    const entry: SourceMapEntry = {
      start: fields[0] !== undefined && fields[0] !== "" ? parseInt(fields[0], 10) : prev.start,
      length: fields[1] !== undefined && fields[1] !== "" ? parseInt(fields[1], 10) : prev.length,
      fileIndex: fields[2] !== undefined && fields[2] !== "" ? parseInt(fields[2], 10) : prev.fileIndex,
      jump: fields[3] !== undefined && fields[3] !== "" ? fields[3] : prev.jump,
    };
    entries.push(entry);
    prev = entry;
  }

  return entries;
}

/**
 * Builds a mapping from PC to instruction index.
 *
 * In EVM bytecode, PUSH1..PUSH32 consume additional bytes for their operand.
 * The source map has one entry per instruction, so we need to know which
 * instruction index a given PC corresponds to.
 */
function buildPcToInstructionIndex(bytecodeHex: string): Map<number, number> {
  // Strip 0x prefix if present
  const hex = bytecodeHex.startsWith("0x") ? bytecodeHex.slice(2) : bytecodeHex;
  const bytes = Buffer.from(hex, "hex");

  const pcToIdx = new Map<number, number>();
  let instructionIndex = 0;
  let pc = 0;

  while (pc < bytes.length) {
    pcToIdx.set(pc, instructionIndex);
    const opcode = bytes[pc];

    // PUSH1 (0x60) through PUSH32 (0x7f) have N immediate bytes
    if (opcode >= 0x60 && opcode <= 0x7f) {
      const pushSize = opcode - 0x5f; // PUSH1 = 1 byte, PUSH32 = 32 bytes
      pc += 1 + pushSize;
    } else {
      pc += 1;
    }
    instructionIndex++;
  }

  return pcToIdx;
}

/**
 * Converts a byte offset in a source file to a 1-based line number.
 */
function byteOffsetToLine(source: string, byteOffset: number): number {
  let line = 1;
  for (let i = 0; i < byteOffset && i < source.length; i++) {
    if (source[i] === "\n") {
      line++;
    }
  }
  return line;
}

export interface ContractSourceMap {
  /** Contract name */
  name: string;
  /** Deployed bytecode hex (with 0x prefix) */
  deployedBytecode: string;
  /** Parsed source map entries (one per instruction) */
  entries: SourceMapEntry[];
  /** PC -> instruction index mapping */
  pcToInstruction: Map<number, number>;
}

/**
 * Loads and parses source map data for a single contract artifact.
 */
export function loadContractSourceMap(artifactPath: string): ContractSourceMap | null {
  if (!fs.existsSync(artifactPath)) {
    return null;
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const deployedBytecode = artifact.deployedBytecode?.object;
  const sourceMapStr = artifact.deployedBytecode?.sourceMap;

  if (!deployedBytecode || !sourceMapStr) {
    return null;
  }

  const name = path.basename(artifactPath, ".json");
  const entries = parseSourceMap(sourceMapStr);
  const pcToInstruction = buildPcToInstructionIndex(deployedBytecode);

  return { name, deployedBytecode, entries, pcToInstruction };
}

/**
 * Given a set of executed PCs for a contract, resolves them to source locations.
 */
export function resolveSourceLocations(
  contractMap: ContractSourceMap,
  executedPCs: Set<number>,
  sourceIdMap: SourceIdMap,
  sourceContents: Map<string, string>
): Map<string, Set<number>> {
  // Map of source file path -> set of hit line numbers
  const fileLines = new Map<string, Set<number>>();

  for (const pc of executedPCs) {
    const instrIdx = contractMap.pcToInstruction.get(pc);
    if (instrIdx === undefined) continue;

    const entry = contractMap.entries[instrIdx];
    if (!entry || entry.fileIndex < 0) continue;

    const filePath = sourceIdMap[entry.fileIndex.toString()];
    if (!filePath) continue;

    // Get source content to compute line number
    const content = sourceContents.get(filePath);
    if (!content) continue;

    const line = byteOffsetToLine(content, entry.start);

    let lines = fileLines.get(filePath);
    if (!lines) {
      lines = new Set();
      fileLines.set(filePath, lines);
    }
    lines.add(line);
  }

  return fileLines;
}

/**
 * Loads source file contents for all files referenced by the source ID map.
 * Resolves paths relative to the project root (l1-contracts/).
 */
export function loadSourceContents(sourceIdMap: SourceIdMap, projectRoot: string): Map<string, string> {
  const contents = new Map<string, string>();

  for (const filePath of Object.values(sourceIdMap)) {
    const absPath = path.resolve(projectRoot, filePath);
    if (fs.existsSync(absPath)) {
      contents.set(filePath, fs.readFileSync(absPath, "utf-8"));
    }
  }

  return contents;
}

export interface FunctionInfo {
  /** Function name as it appears in LCOV: "ContractName.functionName" */
  qualifiedName: string;
  /** 1-based line number of the function declaration */
  line: number;
  /** The source file path */
  file: string;
}

/**
 * Extracts function declarations from a contract's source file.
 *
 * Parses `function <name>(` and `constructor(` patterns from the source,
 * qualifying names as `ContractName.functionName` to match Forge's LCOV format.
 */
export function extractFunctions(
  contractName: string,
  filePath: string,
  sourceContents: Map<string, string>
): FunctionInfo[] {
  const content = sourceContents.get(filePath);
  if (!content) return [];

  const functions: FunctionInfo[] = [];
  const lines = content.split("\n");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Match: function <name>(  or  constructor(
    const funcMatch = line.match(/\bfunction\s+(\w+)\s*\(/);
    const ctorMatch = line.match(/\bconstructor\s*\(/);

    if (funcMatch) {
      functions.push({
        qualifiedName: `${contractName}.${funcMatch[1]}`,
        line: i + 1,
        file: filePath,
      });
    } else if (ctorMatch) {
      functions.push({
        qualifiedName: `${contractName}.constructor`,
        line: i + 1,
        file: filePath,
      });
    }
  }

  return functions;
}

/**
 * Determines which functions were hit based on line coverage data.
 *
 * A function is considered hit if any executable line between its declaration
 * and the next function declaration (or EOF) was covered.
 *
 * @returns Map of qualifiedName -> hit (true/false)
 */
export function resolveFunctionHits(
  functions: FunctionInfo[],
  hitLines: Set<number>
): Map<string, boolean> {
  const result = new Map<string, boolean>();

  // Sort by line number to determine function boundaries
  const sorted = [...functions].sort((a, b) => a.line - b.line);

  for (let i = 0; i < sorted.length; i++) {
    const startLine = sorted[i].line;
    const endLine = i + 1 < sorted.length ? sorted[i + 1].line - 1 : startLine + 200;

    let hit = false;
    for (let line = startLine; line <= endLine; line++) {
      if (hitLines.has(line)) {
        hit = true;
        break;
      }
    }

    result.set(sorted[i].qualifiedName, hit);
  }

  return result;
}

/**
 * Counts the total number of executable lines in a source file by checking
 * which lines appear in any contract's source map.
 */
export function getExecutableLines(
  filePath: string,
  sourceIdMap: SourceIdMap,
  allContractMaps: ContractSourceMap[],
  sourceContents: Map<string, string>
): Set<number> {
  const content = sourceContents.get(filePath);
  if (!content) return new Set();

  // Find the source file index for this path
  let fileIndex = -1;
  for (const [id, p] of Object.entries(sourceIdMap)) {
    if (p === filePath) {
      fileIndex = parseInt(id, 10);
      break;
    }
  }
  if (fileIndex < 0) return new Set();

  const executableLines = new Set<number>();

  for (const contractMap of allContractMaps) {
    for (const entry of contractMap.entries) {
      if (entry.fileIndex === fileIndex && entry.start >= 0 && entry.length > 0) {
        const line = byteOffsetToLine(content, entry.start);
        executableLines.add(line);
      }
    }
  }

  return executableLines;
}
