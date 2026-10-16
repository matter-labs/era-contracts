import * as fs from "fs";
import * as path from "path";
import { stripComments } from "../../../scripts/solc-warnings";
import { NARROW_TEST_OVERRIDES, TARGET_EXCLUDES, TEST_EXCLUDES } from "./config";

export interface Mutant {
  line: number;
  column: number;
  original: string;
  mutant: string;
}

export interface Remapping {
  prefix: string;
  target: string;
}

// The trees that hold compile roots worth skipping.
const PROJECT_DIRS = ["contracts", "test", "deploy-scripts"];
const IMPORT_RE = /\bimport\s+(?:[^;"']*?\bfrom\s+)?["']([^"']+)["']/g;
// Tests load some artifacts by name (`deployCodeTo("X.sol:X")`, `getCreationCodeEVM("X")`) rather than by
// import, so any string literal that names a contract keeps that contract a compile root.
const NAMED_ARTIFACT_RE = /"([A-Za-z_][A-Za-z0-9_]*)(?:\.sol)?(?::[A-Za-z0-9_]+)?"/g;

// `.sol` files under `dir`, relative to `root`.
export function listSol(root: string, dir: string): string[] {
  const out: string[] = [];
  const walk = (rel: string) => {
    const abs = path.join(root, rel);
    if (!fs.existsSync(abs)) {
      return;
    }
    for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
      const child = path.posix.join(rel, entry.name);
      if (entry.isDirectory()) {
        walk(child);
      } else if (entry.name.endsWith(".sol")) {
        out.push(child);
      }
    }
  };
  walk(dir);
  return out.sort();
}

export function isTarget(file: string): boolean {
  return file.startsWith("contracts/") && file.endsWith(".sol") && !TARGET_EXCLUDES.some((re) => re.test(file));
}

// Import graph of the project's own sources, resolved with forge's remappings.
export class SourceGraph {
  private readonly direct = new Map<string, string[]>();

  constructor(
    private readonly root: string,
    private readonly remappings: Remapping[]
  ) {}

  private resolve(from: string, spec: string): string {
    if (spec.startsWith("./") || spec.startsWith("../")) {
      return path.posix.normalize(path.posix.join(path.posix.dirname(from), spec));
    }
    const remap = this.remappings.find((r) => spec.startsWith(r.prefix));
    return remap ? path.posix.normalize(remap.target + spec.slice(remap.prefix.length)) : spec;
  }

  private imports(file: string): string[] {
    let deps = this.direct.get(file);
    if (!deps) {
      const abs = path.join(this.root, file);
      const src = fs.existsSync(abs) ? stripComments(fs.readFileSync(abs, "utf8")) : "";
      deps = [...src.matchAll(IMPORT_RE)].map((m) => this.resolve(file, m[1]));
      this.direct.set(file, deps);
    }
    return deps;
  }

  // Every source reachable through imports from `files`, including them and `lib/` sources.
  closure(files: Iterable<string>): Set<string> {
    const seen = new Set<string>();
    const stack = [...files];
    while (stack.length) {
      const file = stack.pop() as string;
      if (seen.has(file) || !fs.existsSync(path.join(this.root, file))) {
        continue;
      }
      seen.add(file);
      stack.push(...this.imports(file));
    }
    return seen;
  }

  // Forge compiles every source and test helper per mutant; skipping the ones `tests` never reach is the
  // main speed-up. A skipped file is still compiled when imported, but gets no artifact of its own.
  skipList(tests: string[]): string[] {
    const closure = this.closure(tests);
    const named = new Set<string>();
    for (const file of closure) {
      if (PROJECT_DIRS.some((d) => file.startsWith(`${d}/`))) {
        for (const m of fs.readFileSync(path.join(this.root, file), "utf8").matchAll(NAMED_ARTIFACT_RE)) {
          named.add(m[1]);
        }
      }
    }
    return PROJECT_DIRS.flatMap((d) => listSol(this.root, d)).filter(
      (f) => !closure.has(f) && !named.has(path.posix.basename(f, ".sol"))
    );
  }
}

// Test files that can run in forge's mutant workspaces.
export function runnableTests(root: string): string[] {
  return listSol(root, "test/foundry").filter(
    (f) => f.endsWith(".t.sol") && !TEST_EXCLUDES.some((prefix) => f.startsWith(prefix))
  );
}

// Tests whose import closure contains `target`.
export function broadTests(graph: SourceGraph, target: string, tests: string[]): string[] {
  return tests.filter((t) => graph.closure([t]).has(target));
}

// The target's own tests: an override, or test files and directories named after it.
export function narrowTests(target: string, broad: string[]): string[] {
  const overrides = NARROW_TEST_OVERRIDES[target];
  const name = path.posix.basename(target, ".sol");
  return broad.filter((t) => {
    if (overrides) {
      return overrides.some((prefix) => t.startsWith(prefix));
    }
    const base = path.posix.basename(t, ".t.sol");
    return base === name || base.startsWith(`${name}_`) || t.split("/").slice(0, -1).includes(name);
  });
}

// Forge has no operator that removes a whole `if (cond) { revert ... }` guard, the codebase's usual form
// of a check, so these mutants replace the condition with `false`.
export function guardMutants(src: string): Mutant[] {
  const code = stripComments(src);
  const mutants: Mutant[] = [];
  for (const m of code.matchAll(/\bif\s*\(/g)) {
    const start = (m.index as number) + m[0].length;
    let depth = 1;
    let i = start;
    while (depth && i < code.length) {
      depth += code[i] === "(" ? 1 : code[i] === ")" ? -1 : 0;
      i++;
    }
    const rest = code.slice(i).trimStart();
    if (!rest.startsWith("{") || !rest.slice(1).trimStart().startsWith("revert")) {
      continue;
    }
    mutants.push({
      line: code.slice(0, start).split("\n").length,
      column: start - (code.lastIndexOf("\n", start - 1) + 1) + 1,
      original: src.slice(start, i - 1),
      mutant: "false",
    });
  }
  return mutants;
}

// `src` with `m` applied at its line and column (1-based), or undefined if the text there differs.
export function applyMutant(src: string, m: Mutant): string | undefined {
  const offset =
    src
      .split("\n")
      .slice(0, m.line - 1)
      .reduce((n, l) => n + l.length + 1, 0) +
    m.column -
    1;
  if (src.slice(offset, offset + m.original.length) !== m.original) {
    return undefined;
  }
  return src.slice(0, offset) + m.mutant + src.slice(offset + m.original.length);
}
