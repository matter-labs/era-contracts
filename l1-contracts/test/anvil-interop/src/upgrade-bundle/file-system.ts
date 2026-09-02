import { createHash } from "crypto";
import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "@iarna/toml";
import type { TomlRecord } from "./types";

function findPackageDirectory(start: string): string {
  let current = path.resolve(start);
  let previous = "";
  while (current !== previous) {
    const packagePath = path.join(current, "package.json");
    if (fs.existsSync(packagePath) && readJson<{ name?: string }>(packagePath).name === "anvil-interop") return current;
    previous = current;
    current = path.dirname(current);
  }
  throw new Error("Cannot locate the anvil-interop package directory");
}

export const ANVIL_INTEROP_DIR = findPackageDirectory(__dirname);
export const L1_CONTRACTS_DIR = path.resolve(ANVIL_INTEROP_DIR, "../..");
export const REPO_ROOT = path.resolve(L1_CONTRACTS_DIR, "..");

export function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function readJson<T>(filePath: string): T {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
  } catch (error) {
    throw new Error(`Cannot read JSON ${filePath}: ${formatError(error)}`);
  }
}

export function readToml(filePath: string): TomlRecord {
  try {
    return parseToml(fs.readFileSync(filePath, "utf8")) as TomlRecord;
  } catch (error) {
    throw new Error(`Cannot read TOML ${filePath}: ${formatError(error)}`);
  }
}

function tomlValue(config: TomlRecord, keyPath: string): unknown {
  return keyPath.split(".").reduce<unknown>((value, key) => {
    if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
    return (value as TomlRecord)[key];
  }, config);
}

export function requireTomlString(config: TomlRecord, keyPath: string, source: string): string {
  const value = tomlValue(config, keyPath);
  if (typeof value !== "string" || value.length === 0) throw new Error(`${keyPath} not found in ${source}`);
  return value;
}

export function optionalTomlString(config: TomlRecord, keyPath: string): string | undefined {
  const value = tomlValue(config, keyPath);
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function optionalTomlInteger(config: TomlRecord, keyPath: string): number | undefined {
  const value = tomlValue(config, keyPath);
  return typeof value === "number" && Number.isSafeInteger(value) ? value : undefined;
}

export function fileSha256(filePath: string): string {
  return createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

export function requireFile(filePath: string, context = "file"): void {
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    throw new Error(`${context} not found: ${filePath}`);
  }
}

function escapesDirectory(relativePath: string): boolean {
  return relativePath === ".." || relativePath.startsWith(`..${path.sep}`) || path.isAbsolute(relativePath);
}

export function resolveContainedFile(directory: string, relativePath: string, context: string): string {
  if (!relativePath) throw new Error(`${context}: empty file path`);
  const root = fs.realpathSync(directory);
  const candidatePath = path.resolve(root, relativePath);
  const unresolvedRelative = path.relative(root, candidatePath);
  if (escapesDirectory(unresolvedRelative)) {
    throw new Error(`${context}: ${relativePath}`);
  }
  requireFile(candidatePath, context);
  const candidate = fs.realpathSync(candidatePath);
  const relative = path.relative(root, candidate);
  if (escapesDirectory(relative)) throw new Error(`${context}: ${relativePath}`);
  return candidate;
}

export function writeCombinedLog(destination: string, sources: string[]): void {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const contents = sources.filter((source) => fs.existsSync(source)).map((source) => fs.readFileSync(source));
  fs.writeFileSync(destination, Buffer.concat(contents));
}

export function parseInteger(value: string | undefined, label: string): number | undefined {
  if (value === undefined || value === "") return undefined;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${label} must be a non-negative integer`);
  return parsed;
}
