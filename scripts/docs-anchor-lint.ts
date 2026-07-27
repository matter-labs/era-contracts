import { execSync } from "child_process";
import * as fs from "fs";
import { join } from "path";

// Validates every `{protocol-docs/<file>.md(#anchor)?}` reference embedded in the
// source tree: the target file must exist, and any `#anchor` must resolve to a real
// heading in that file (GitHub slug rules). Keeps doc pointers from silently rotting
// as `protocol-docs/` evolves. See AGENTS.md "Documentation and Comments".
//
// Parsing is deliberately two-phase, so the lint fails CLOSED:
//   1. DISCOVERY finds every `{protocol-docs…}` candidate with a permissive pattern.
//   2. VALIDATION checks each candidate against the strict grammar, then resolves it.
// A single-phase strict regex would silently ignore malformed pointers (a typo like
// `#does.not-exist` simply wouldn't match), which is exactly the rot this guards against.
// Run with `--selftest` to exercise the parser against the cases below.

const DOCS_DIR = "protocol-docs";
// Extensions carrying `{protocol-docs/...}` pointers. `*.md` is included because the docs
// cross-reference each other with the same syntax, and those pointers rot just as easily.
const SOURCE_GLOBS = ["*.sol", "*.ts", "*.rs", "*.md"];

// Phase 1 — permissive discovery: anything that opens `{protocol-docs` and closes on the
// same line. Deliberately loose so malformed pointers are *found* and then rejected.
const CANDIDATE_RE = /\{protocol-docs[^}\n]*\}/g;
// An opener with no closing brace on the line: also malformed, and invisible to the above.
const UNTERMINATED_RE = /\{protocol-docs[^}\n]*$/gm;

// Prose that documents the pointer *syntax* (AGENTS.md, protocol-docs/README.md) writes templates
// like `{protocol-docs/<path>.md}` or `{protocol-docs/...}`. A real pointer can never contain an
// angle bracket or an ellipsis, so skipping these does not fail open: a realistic typo such as
// `#does.not-exist` has neither and is still reported.
const TEMPLATE_RE = /[<>]|\.\.\./;

// Phase 2 — the strict grammar a pointer must satisfy.
// Path segments allow dots so filenames like `foo.bar.md` parse; the anchor accepts
// Unicode letters/numbers (GitHub keeps them) and a backslash before a character, because
// prettier escapes underscores in markdown prose (`#\_recoverbundle`).
const STRICT_RE = /^\{protocol-docs\/((?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+\.md)(#(?:\\?[\p{L}\p{N}_-])+)?\}$/u;

// GitHub heading -> anchor slug (mirrors github-slugger): lowercase, drop every character
// that is not a letter, number, space, hyphen or underscore, then turn spaces into hyphens.
// `\p{L}`/`\p{N}` rather than `\w` so non-ASCII headings slug like they do on GitHub.
// Duplicate slugs within one file get `-1`, `-2`, ... suffixes.
export function slugify(heading: string, seen: Map<string, number>): string {
  const base = heading
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/\s/g, "-");
  const count = seen.get(base) ?? 0;
  seen.set(base, count + 1);
  return count === 0 ? base : `${base}-${count}`;
}

export type Parsed = { ok: true; docFile: string; anchor?: string } | { ok: false; reason: string };

// Validates one discovered candidate against the strict grammar.
export function parsePointer(candidate: string): Parsed {
  const m = STRICT_RE.exec(candidate);
  if (!m) return { ok: false, reason: "malformed pointer syntax" };
  return { ok: true, docFile: m[1], anchor: m[2] };
}

// Normalizes an anchor for slug comparison: strip the leading `#` and prettier's escaping.
export function anchorToSlug(anchor: string): string {
  return anchor.slice(1).replace(/\\/g, "").toLowerCase();
}

// Returns the set of valid anchor slugs for a markdown file, honouring fenced code
// blocks (```) so a `#` inside a code sample is not mistaken for a heading.
function anchorsForDoc(mdPath: string): Set<string> {
  const slugs = new Set<string>();
  const seen = new Map<string, number>();
  let inFence = false;
  for (const line of fs.readFileSync(mdPath, "utf-8").split("\n")) {
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const m = /^(#{1,6})\s+(.*)$/.exec(line);
    if (m) slugs.add(slugify(m[2], seen));
  }
  return slugs;
}

// This file is excluded from its own scan: it defines the grammar and deliberately contains
// malformed pointers as `--selftest` fixtures, which would otherwise be reported as violations.
const SELF_PATH = "scripts/docs-anchor-lint.ts";

function listedSourceFiles(): string[] {
  const out = execSync(`git ls-files ${SOURCE_GLOBS.map((g) => `'${g}'`).join(" ")}`, {
    encoding: "utf-8",
    maxBuffer: 64 * 1024 * 1024,
  });
  return out
    .split("\n")
    .filter(Boolean)
    .filter((f) => f !== SELF_PATH);
}

// Keyed by path relative to DOCS_DIR (e.g. `atomicity/flow.md`), so nested docs are addressable
// exactly as they appear in a `{protocol-docs/<relPath>}` pointer.
function loadDocAnchors(): Map<string, Set<string>> {
  const map = new Map<string, Set<string>>();
  const walk = (dir: string, prefix: string): void => {
    for (const entry of fs.readdirSync(join(DOCS_DIR, dir), { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        walk(join(dir, entry.name), rel);
      } else if (entry.name.endsWith(".md")) {
        map.set(rel, anchorsForDoc(join(DOCS_DIR, rel)));
      }
    }
  };
  walk("", "");
  return map;
}

function printList(docAnchors: Map<string, Set<string>>): void {
  for (const [file, anchors] of [...docAnchors].sort()) {
    console.log(`\n${DOCS_DIR}/${file}`);
    for (const a of anchors) console.log(`  #${a}`);
  }
}

function lineOf(content: string, index: number): number {
  return content.slice(0, index).split("\n").length;
}

function check(docAnchors: Map<string, Set<string>>): number {
  const violations: string[] = [];
  let checked = 0;

  for (const file of listedSourceFiles()) {
    const content = fs.readFileSync(file, "utf-8");

    // Unterminated openers first — these never reach the candidate scanner.
    UNTERMINATED_RE.lastIndex = 0;
    let u: RegExpExecArray | null;
    while ((u = UNTERMINATED_RE.exec(content)) !== null) {
      violations.push(`${file}:${lineOf(content, u.index)}: unterminated pointer '${u[0].trim()}' (missing '}')`);
    }

    CANDIDATE_RE.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = CANDIDATE_RE.exec(content)) !== null) {
      if (TEMPLATE_RE.test(m[0])) continue; // syntax documentation, not a pointer
      checked++;
      const where = `${file}:${lineOf(content, m.index)}`;
      const parsed = parsePointer(m[0]);
      if (!parsed.ok) {
        violations.push(`${where}: ${parsed.reason}: '${m[0]}'`);
        continue;
      }
      const anchors = docAnchors.get(parsed.docFile);
      if (!anchors) {
        violations.push(`${where}: references missing doc '${DOCS_DIR}/${parsed.docFile}'`);
        continue;
      }
      if (parsed.anchor && !anchors.has(anchorToSlug(parsed.anchor))) {
        violations.push(`${where}: anchor '${parsed.anchor}' not found in ${DOCS_DIR}/${parsed.docFile}`);
      }
    }
  }

  if (violations.length) {
    console.error(`docs-anchor-lint: ${violations.length} broken protocol-docs reference(s):`);
    for (const v of violations) console.error(`  ${v}`);
    return 1;
  }
  console.log(`docs-anchor-lint: all ${checked} protocol-docs references resolve.`);
  return 0;
}

// Parser tests. Run via `yarn docs-anchor-lint --selftest`; wired into `lint:check` so the
// grammar cannot regress silently.
function selftest(): number {
  const failures: string[] = [];
  const expectOk = (s: string, docFile: string, anchor?: string) => {
    const p = parsePointer(s);
    if (!p.ok) return failures.push(`expected OK, got '${p.reason}': ${s}`);
    if (p.docFile !== docFile) failures.push(`docFile '${p.docFile}' != '${docFile}': ${s}`);
    if (p.anchor !== anchor) failures.push(`anchor '${p.anchor}' != '${anchor}': ${s}`);
  };
  const expectBad = (s: string) => {
    if (parsePointer(s).ok) failures.push(`expected MALFORMED, got OK: ${s}`);
  };

  // well-formed
  expectOk("{protocol-docs/interop.md}", "interop.md", undefined);
  expectOk("{protocol-docs/interop.md#send-flow}", "interop.md", "#send-flow");
  expectOk("{protocol-docs/atomicity/flow.md#data-structures}", "atomicity/flow.md", "#data-structures");
  expectOk("{protocol-docs/a/b/c.md#x}", "a/b/c.md", "#x");
  // prettier-escaped underscore must parse, not be skipped
  expectOk("{protocol-docs/atomicity/recovery.md#\\_recoverbundle}", "atomicity/recovery.md", "#\\_recoverbundle");
  // unicode anchors are legal on GitHub
  expectOk("{protocol-docs/interop.md#überblick}", "interop.md", "#überblick");

  // malformed — each of these used to be silently ignored
  expectBad("{protocol-docs/interop.md#does.not-exist}"); // '.' illegal in an anchor
  expectBad("{protocol-docs/interop.md#has space}");
  expectBad("{protocol-docs/interop.md#}"); // empty anchor
  expectBad("{protocol-docs/interop.txt}"); // not a .md target
  expectBad("{protocol-docs/interop.md#a#b}");
  expectBad("{protocol-docs}"); // no file at all
  expectBad("{protocol-docs/}");
  expectBad("{protocol-docs/interop.md #send-flow}");

  // syntax-documentation templates are skipped, but only because of `<`/`>`/`...`
  const expectTemplate = (s: string, isTemplate: boolean) => {
    if (TEMPLATE_RE.test(s) !== isTemplate) {
      failures.push(`TEMPLATE_RE.test('${s}') should be ${isTemplate}`);
    }
  };
  expectTemplate("{protocol-docs/<path>.md}", true);
  expectTemplate("{protocol-docs/...}", true);
  expectTemplate("{protocol-docs/interop.md#does.not-exist}", false); // a real typo must NOT be exempted
  expectTemplate("{protocol-docs/atomicity/flow.md#data-structures}", false);

  // slug rules
  const seen = new Map<string, number>();
  if (slugify("`_recoverBundle`: reversing the burns", seen) !== "_recoverbundle-reversing-the-burns") {
    failures.push("slugify: backtick/colon handling regressed");
  }
  if (slugify("Überblick", new Map()) !== "überblick") {
    failures.push("slugify: non-ASCII letters must survive (GitHub keeps them)");
  }
  const dup = new Map<string, number>();
  slugify("Same", dup);
  if (slugify("Same", dup) !== "same-1") failures.push("slugify: duplicate suffixing regressed");
  if (anchorToSlug("#\\_foo-bar") !== "_foo-bar") failures.push("anchorToSlug: escape stripping regressed");

  if (failures.length) {
    console.error(`docs-anchor-lint --selftest: ${failures.length} failure(s):`);
    for (const f of failures) console.error(`  ${f}`);
    return 1;
  }
  console.log("docs-anchor-lint --selftest: parser tests pass.");
  return 0;
}

function main(): void {
  if (process.argv.includes("--selftest")) {
    process.exit(selftest());
  }
  const docAnchors = loadDocAnchors();
  if (process.argv.includes("--list")) {
    printList(docAnchors);
    return;
  }
  process.exit(check(docAnchors));
}

main();
