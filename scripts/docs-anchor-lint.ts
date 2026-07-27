import { execSync } from "child_process";
import * as fs from "fs";
import { join } from "path";

// Validates every `{protocol-docs/<file>.md(#anchor)?}` reference embedded in the
// source tree: the target file must exist, and any `#anchor` must resolve to a real
// heading in that file (GitHub slug rules). Keeps doc pointers from silently rotting
// as `protocol-docs/` evolves. See AGENTS.md "Documentation and Comments".

const DOCS_DIR = "protocol-docs";
// Extensions carrying `{protocol-docs/...}` pointers. `*.md` is included because the docs
// cross-reference each other with the same syntax, and those pointers rot just as easily.
const SOURCE_GLOBS = ["*.sol", "*.ts", "*.rs", "*.md"];
// The doc target may be nested (e.g. `atomicity/flow.md`), so allow one or more path segments.
// The anchor accepts a backslash before `_` because prettier escapes underscores in markdown
// prose (`#\_recoverbundle`); such a pointer must still be validated, not silently skipped.
const POINTER_RE = /\{protocol-docs\/((?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+\.md)(#(?:\\?[A-Za-z0-9_-])+)?\}/g;

// GitHub heading -> anchor slug (mirrors github-slugger): lowercase, drop every
// character that is not a letter, number, space, hyphen or underscore, then turn
// spaces into hyphens. Duplicate slugs within one file get `-1`, `-2`, ... suffixes.
function slugify(heading: string, seen: Map<string, number>): string {
  const base = heading
    .trim()
    .toLowerCase()
    .replace(/[^\w\s-]/g, "")
    .replace(/\s/g, "-");
  const count = seen.get(base) ?? 0;
  seen.set(base, count + 1);
  return count === 0 ? base : `${base}-${count}`;
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

function listedSourceFiles(): string[] {
  const out = execSync(`git ls-files ${SOURCE_GLOBS.map((g) => `'${g}'`).join(" ")}`, {
    encoding: "utf-8",
    maxBuffer: 64 * 1024 * 1024,
  });
  return out.split("\n").filter(Boolean);
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

function check(docAnchors: Map<string, Set<string>>): number {
  const violations: string[] = [];
  for (const file of listedSourceFiles()) {
    const content = fs.readFileSync(file, "utf-8");
    let m: RegExpExecArray | null;
    POINTER_RE.lastIndex = 0;
    while ((m = POINTER_RE.exec(content)) !== null) {
      const [, docFile, anchor] = m;
      const lineNo = content.slice(0, m.index).split("\n").length;
      const where = `${file}:${lineNo}`;
      const anchors = docAnchors.get(docFile);
      if (!anchors) {
        violations.push(`${where}: references missing doc '${DOCS_DIR}/${docFile}'`);
        continue;
      }
      if (anchor) {
        // Drop prettier's markdown escaping (`#\_foo` -> `#_foo`) before matching slugs.
        const slug = anchor.slice(1).replace(/\\/g, "");
        if (!anchors.has(slug)) {
          violations.push(`${where}: anchor '${anchor}' not found in ${DOCS_DIR}/${docFile}`);
        }
      }
    }
  }
  if (violations.length) {
    console.error(`docs-anchor-lint: ${violations.length} broken protocol-docs reference(s):`);
    for (const v of violations) console.error(`  ${v}`);
    return 1;
  }
  console.log("docs-anchor-lint: all protocol-docs references resolve.");
  return 0;
}

function main(): void {
  const docAnchors = loadDocAnchors();
  if (process.argv.includes("--list")) {
    printList(docAnchors);
    return;
  }
  process.exit(check(docAnchors));
}

main();
