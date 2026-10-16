// Mutation testing for l1-contracts. See docs/mutation-testing.md.
import { Command } from "commander";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { DEFAULT_MUTANT_TIMEOUT_S, EXCEPTIONS_FILE, STATEMENT_EXCLUDED_OPERATORS, WORK_DIR } from "./config";
import type { ForgeSummary } from "./run";
import { checkForge, forgePass, loadRemappings, recheck, workersFor } from "./run";
import type { Mutant } from "./sources";
import { SourceGraph, broadTests, guardMutants, isTarget, listSol, narrowTests, runnableTests } from "./sources";

const ROOT = path.resolve(__dirname, "../..");

interface Exception {
  file: string;
  source: string;
  original: string;
  mutant: string;
  reason: string;
}

interface Survivor extends Mutant {
  source: string;
  kind: "forge" | "guard";
  reason?: string;
}

interface TargetResult {
  file: string;
  narrowTests: number;
  broadTests: number;
  forge?: ForgeSummary;
  guards: number;
  survivors: Survivor[];
  note?: string;
}

function git(args: string[]): string {
  return execFileSync("git", args, { cwd: ROOT, encoding: "utf8" });
}

// Lines added or changed since the merge base with `base`, working tree included.
function changedLines(base: string, file: string): Set<number> {
  const lines = new Set<number>();
  for (const m of git(["diff", "--merge-base", base, "-U0", "--", file]).matchAll(/^@@ .* \+(\d+)(?:,(\d+))? @@/gm)) {
    const start = Number(m[1]);
    for (let i = 0; i < Number(m[2] ?? 1); i++) {
      lines.add(start + i);
    }
  }
  return lines;
}

function resolveTargets(files: string[], opts: { base?: string; all?: boolean }): string[] {
  let candidates: string[];
  if (opts.all) {
    candidates = listSol(ROOT, "contracts");
  } else if (opts.base) {
    candidates = git(["diff", "--merge-base", opts.base, "--name-only", "--relative", "--", "contracts"])
      .split("\n")
      .filter((f) => f && fs.existsSync(path.join(ROOT, f)));
  } else {
    // yarn runs workspace scripts from l1-contracts/; INIT_CWD is where the user typed the command.
    const bases = [process.env.INIT_CWD ?? process.cwd(), ROOT];
    candidates = files.map((f) => {
      const abs = bases.map((b) => path.resolve(b, f)).find((p) => fs.existsSync(p)) ?? path.resolve(ROOT, f);
      return path.relative(ROOT, abs).split(path.sep).join("/");
    });
  }
  if (files.length) {
    for (const f of candidates.filter((c) => !isTarget(c))) {
      console.warn(`skipping ${f}: not an in-scope contract (see TARGET_EXCLUDES)`);
    }
  }
  return candidates.filter(isTarget);
}

function exceptionKey(e: { file: string; source: string; original: string; mutant: string }): string {
  return [e.file, e.source, e.original, e.mutant].join("\0");
}

function cell(text: string): string {
  return "`" + text.replace(/\s+/g, " ").replace(/\|/g, "\\|") + "`";
}

function render(results: TargetResult[], fullMode: boolean, stale: Exception[]): string {
  const out = ["## Mutation testing", ""];
  out.push("| File | Tests (own / broad) | Mutants | Killed | Survived | Untriaged |");
  out.push("| --- | ---: | ---: | ---: | ---: | ---: |");
  for (const r of results) {
    const forgeEvaluated = r.forge ? r.forge.killed + r.forge.survived : 0;
    const mutants = fullMode ? String(forgeEvaluated + r.guards) : "changed lines";
    const killed = fullMode ? String(forgeEvaluated + r.guards - r.survivors.length) : "-";
    const untriaged = r.survivors.filter((s) => !s.reason).length;
    out.push(
      `| ${r.note ? `${r.file} (${r.note})` : r.file} | ${r.narrowTests} / ${r.broadTests} | ${mutants} | ${killed} | ` +
        `${r.survivors.length} | ${untriaged} |`
    );
  }
  for (const r of results) {
    const untriaged = r.survivors.filter((s) => !s.reason);
    if (!untriaged.length) {
      continue;
    }
    out.push("", `### ${r.file}`, "", "| Line | Mutation | Source |", "| ---: | --- | --- |");
    for (const s of untriaged) {
      out.push(`| ${s.line} | ${cell(s.original)} → ${cell(s.mutant)} | ${cell(s.source)} |`);
    }
  }
  if (stale.length) {
    out.push("", `### Stale entries in ${EXCEPTIONS_FILE}`, "");
    for (const e of stale) {
      out.push(`- ${e.file}: ${cell(e.original)} → ${cell(e.mutant)} in ${cell(e.source)}`);
    }
  }
  return out.join("\n") + "\n";
}

async function main() {
  const program = new Command()
    .name("mutation")
    .description("Mutation testing for l1-contracts (docs/mutation-testing.md)")
    .argument("[files...]", "contracts to mutate, e.g. contracts/common/libraries/Merkle.sol")
    .option("--base <ref>", "mutate contracts changed since the merge base with <ref>; report changed lines only")
    .option("--all", "mutate every in-scope contract")
    .option("--operators <set>", "all | statement (require, delete, assignment)", "all")
    .option("--no-guards", "skip the guard-removal mutants")
    .option("--no-recheck", "do not re-check survivors against every test that imports the contract")
    .option("--jobs <n>", "parallel workers (default: what fits in free memory)", (v) => parseInt(v, 10))
    .option("--timeout <s>", "per-mutant timeout", (v) => parseInt(v, 10), DEFAULT_MUTANT_TIMEOUT_S)
    .option("--json <path>", "write the full results as JSON")
    .option("--check", "exit 1 on untriaged survivors or stale exceptions")
    .parse(process.argv);
  const opts = program.opts();
  const fullMode = !opts.base && opts.operators === "all" && opts.guards && opts.recheck;
  if (opts.operators === "statement") {
    process.env.FOUNDRY_MUTATION_EXCLUDE_OPERATORS = JSON.stringify(STATEMENT_EXCLUDED_OPERATORS);
  }

  checkForge();
  const targets = resolveTargets(program.args, opts);
  if (!targets.length) {
    console.log("No in-scope contracts to mutate.");
    return;
  }
  const workDir = path.join(ROOT, WORK_DIR);
  fs.mkdirSync(workDir, { recursive: true });
  const configsLink = path.join(workDir, "configs");
  if (!fs.existsSync(configsLink)) {
    fs.symlinkSync(fs.realpathSync(path.join(ROOT, "..", "configs")), configsLink);
  }

  const exceptions: Exception[] = JSON.parse(fs.readFileSync(path.join(ROOT, EXCEPTIONS_FILE), "utf8"));
  const triage = new Map(exceptions.map((e) => [exceptionKey(e), e]));
  const used = new Set<string>();
  const graph = new SourceGraph(ROOT, loadRemappings(ROOT));
  const tests = runnableTests(ROOT);
  const results: TargetResult[] = [];

  for (const target of targets) {
    const broad = broadTests(graph, target, tests);
    const own = narrowTests(target, broad);
    const result: TargetResult = {
      file: target,
      narrowTests: own.length,
      broadTests: broad.length,
      guards: 0,
      survivors: [],
    };
    results.push(result);
    if (!broad.length) {
      result.note = "no runnable test imports it";
      console.log(`${target}: no runnable test imports it`);
      continue;
    }
    const src = fs.readFileSync(path.join(ROOT, target), "utf8");
    const sourceLines = src.split("\n");
    const inScope = opts.base ? changedLines(opts.base, target) : undefined;
    const keep = (m: Mutant) => !inScope || inScope.has(m.line);

    const first = own.length ? own : broad;
    console.log(`${target}: forge pass against ${first.length} test file(s)`);
    const pass = await forgePass({
      root: ROOT,
      workDir,
      target,
      tests: first,
      skips: graph.skipList(first),
      jobs: workersFor(graph.closure(first).size, opts.jobs),
      timeoutS: opts.timeout,
    });
    result.forge = pass.summary;

    const candidates: Survivor[] = pass.survivors.filter(keep).map((m) => ({ ...m, kind: "forge", source: "" }));
    if (opts.guards) {
      const guards = guardMutants(src).filter(keep);
      result.guards = guards.length;
      candidates.push(...guards.map((m): Survivor => ({ ...m, kind: "guard", source: "" })));
    }
    let survivors = candidates;
    const toRecheck = candidates.filter((c) => c.kind === "guard" || (opts.recheck && own.length));
    if (toRecheck.length) {
      console.log(`${target}: re-checking ${toRecheck.length} mutant(s) against ${broad.length} test file(s)`);
      const verdicts = await recheck({
        root: ROOT,
        workDir,
        target,
        mutants: toRecheck,
        tests: broad,
        skips: graph.skipList(broad),
        jobs: workersFor(graph.closure(broad).size, opts.jobs),
      });
      const dead = new Set(toRecheck.filter((_, i) => verdicts[i] !== "survived"));
      survivors = candidates.filter((c) => !dead.has(c));
    }
    for (const s of survivors) {
      s.source = (sourceLines[s.line - 1] ?? "").trim();
      const key = exceptionKey({ file: target, ...s });
      const exception = triage.get(key);
      if (exception) {
        s.reason = exception.reason;
        used.add(key);
      }
    }
    result.survivors = survivors;
    console.log(`${target}: ${survivors.length} survivor(s), ${survivors.filter((s) => !s.reason).length} untriaged`);
  }

  const mutated = new Set(results.filter((r) => r.forge).map((r) => r.file));
  const stale = fullMode ? exceptions.filter((e) => mutated.has(e.file) && !used.has(exceptionKey(e))) : [];
  const report = render(results, fullMode, stale);
  console.log(report);
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, report);
  }
  if (opts.json) {
    fs.writeFileSync(opts.json, JSON.stringify(results, null, 2) + "\n");
  }
  const untriaged = results.reduce((n, r) => n + r.survivors.filter((s) => !s.reason).length, 0);
  if (opts.check && (untriaged || stale.length)) {
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
