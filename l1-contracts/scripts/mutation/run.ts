import { execFileSync, spawn } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import {
  MB_PER_SOURCE,
  PROFILE,
  MEMORY_HEADROOM,
  MIN_WORKER_MB,
  RESERVE_MB,
  WORKSPACE_DIRS,
  WORKSPACE_FILES,
} from "./config";
import type { Mutant, Remapping } from "./sources";
import { applyMutant } from "./sources";

export const FORGE = process.env.FORGE || "forge";

export interface ForgeSummary {
  total: number;
  killed: number;
  survived: number;
  invalid: number;
  skipped: number;
  timed_out: number;
}

export interface ForgePass {
  summary: ForgeSummary;
  survivors: Mutant[];
  narrowed: boolean;
}

export type Verdict = "killed" | "survived" | "invalid" | "unapplied";

interface Exec {
  code: number;
  stdout: string;
  stderr: string;
}

function exec(cmd: string, args: string[], cwd: string, env: NodeJS.ProcessEnv): Promise<Exec> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd, env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

export function checkForge(): void {
  const help = execFileSync(FORGE, ["test", "--help"], { encoding: "utf8" });
  if (!help.includes("--mutate")) {
    const version = execFileSync(FORGE, ["--version"], { encoding: "utf8" }).split("\n")[0];
    throw new Error(
      `${version} has no \`forge test --mutate\`. Use Foundry v1.8.0 or later; repeatable results need a ` +
        "build with foundry-rs/foundry#17423 (point FORGE at it). See docs/mutation-testing.md."
    );
  }
}

export function loadRemappings(root: string): Remapping[] {
  return execFileSync(FORGE, ["remappings"], { cwd: root, encoding: "utf8" })
    .split("\n")
    .filter((l) => l.includes("="))
    .map((l) => {
      const [prefix, target] = l.replace(/^[^:=]*:/, "").split("=");
      return { prefix, target };
    })
    .sort((a, b) => b.prefix.length - a.prefix.length);
}

// Workers that fit in free memory, each compiling `sources` files unoptimized.
export function workersFor(sources: number, requested?: number): number {
  if (requested) {
    return requested;
  }
  const perWorkerMb = Math.max(MIN_WORKER_MB, sources * MB_PER_SOURCE) * MEMORY_HEADROOM;
  const freeMb = os.freemem() / 2 ** 20 - RESERVE_MB;
  return Math.max(1, Math.min(os.cpus().length, Math.floor(freeMb / perWorkerMb)));
}

function matchPath(tests: string[]): string {
  return `{${tests.join(",")}}`;
}

function skipArgs(skips: string[]): string[] {
  return skips.flatMap((s) => ["--skip", s]);
}

// The JSON summary is the last object forge prints.
function parseForgeJson(stdout: string): { summary: ForgeSummary; survived_mutants: Record<string, Mutant[]> } {
  const starts = [...stdout.matchAll(/\{"summary"/g)];
  if (!starts.length) {
    throw new Error("forge printed no mutation summary");
  }
  return JSON.parse(stdout.slice(starts[starts.length - 1].index));
}

// Runs forge's own mutation pass on `target` against `tests`.
export async function forgePass(opts: {
  root: string;
  workDir: string;
  target: string;
  tests: string[];
  skips: string[];
  jobs: number;
  timeoutS: number;
}): Promise<ForgePass> {
  const env = { ...process.env, FOUNDRY_PROFILE: PROFILE, TMPDIR: opts.workDir };
  const run = (skips: string[]) =>
    exec(
      FORGE,
      [
        "test",
        "--mutate",
        opts.target,
        "--match-path",
        matchPath(opts.tests),
        "--mutation-jobs",
        String(opts.jobs),
        "--mutation-timeout",
        String(opts.timeoutS),
        "--json",
        ...skipArgs(skips),
      ],
      opts.root,
      env
    );
  let narrowed = opts.skips.length > 0;
  let result = await run(opts.skips);
  if (narrowed && result.code !== 0 && result.stderr.includes("baseline")) {
    // The import scan missed a source some test loads by name; correctness over speed.
    console.warn(`  baseline failed with narrowed compilation, retrying ${opts.target} without --skip`);
    narrowed = false;
    result = await run([]);
  }
  if (result.code !== 0) {
    throw new Error(`forge failed on ${opts.target}:\n${result.stderr.slice(-4000)}`);
  }
  const parsed = parseForgeJson(result.stdout);
  return { summary: parsed.summary, survivors: Object.values(parsed.survived_mutants).flat(), narrowed };
}

function prepareWorkspace(root: string, workDir: string, index: number): string {
  const base = path.join(workDir, `ws${index}`);
  const ws = path.join(base, "l1-contracts");
  fs.mkdirSync(ws, { recursive: true });
  // `out/` and the cache stay, so each run compiles incrementally.
  for (const dir of WORKSPACE_DIRS) {
    fs.rmSync(path.join(ws, dir), { recursive: true, force: true });
    if (fs.existsSync(path.join(root, dir))) {
      fs.cpSync(path.join(root, dir), path.join(ws, dir), { recursive: true, verbatimSymlinks: true });
    }
  }
  for (const file of WORKSPACE_FILES) {
    if (fs.existsSync(path.join(root, file))) {
      fs.copyFileSync(path.join(root, file), path.join(ws, file));
    }
  }
  const links: [string, string][] = [
    [path.join(ws, "lib"), fs.realpathSync(path.join(root, "lib"))],
    [path.join(base, "configs"), fs.realpathSync(path.join(root, "..", "configs"))],
  ];
  for (const [link, target] of links) {
    if (!fs.existsSync(link)) {
      fs.symlinkSync(target, link);
    }
  }
  fs.mkdirSync(path.join(ws, "script-out"), { recursive: true });
  return ws;
}

// Re-runs each mutant against `tests` in persistent workspaces, so mutants that only survived a narrow
// test set, and mutants forge cannot generate, are judged against the wider suite.
export async function recheck(opts: {
  root: string;
  workDir: string;
  target: string;
  mutants: Mutant[];
  tests: string[];
  skips: string[];
  jobs: number;
}): Promise<Verdict[]> {
  const env = { ...process.env, FOUNDRY_PROFILE: PROFILE };
  const workers = Math.min(opts.jobs, opts.mutants.length);
  const workspaces = Array.from({ length: workers }, (_, i) => prepareWorkspace(opts.root, opts.workDir, i));
  const baseline = async (skips: string[]) => {
    const args = ["test", "--fail-fast", "--match-path", matchPath(opts.tests), ...skipArgs(skips)];
    const runs = await Promise.all(workspaces.map((ws) => exec(FORGE, args, ws, env)));
    return { args, failed: runs.find((r) => r.code !== 0) };
  };
  let { args, failed } = await baseline(opts.skips);
  if (failed && opts.skips.length) {
    console.warn(`  re-check baseline failed with narrowed compilation, retrying ${opts.target} without --skip`);
    ({ args, failed } = await baseline([]));
  }
  if (failed) {
    throw new Error(`re-check baseline failed for ${opts.target}:\n${failed.stdout.slice(-4000)}`);
  }
  const verdicts: Verdict[] = new Array(opts.mutants.length);
  let next = 0;
  await Promise.all(
    workspaces.map(async (ws) => {
      const file = path.join(ws, opts.target);
      const original = fs.readFileSync(file, "utf8");
      while (next < opts.mutants.length) {
        const i = next++;
        const mutated = applyMutant(original, opts.mutants[i]);
        if (mutated === undefined) {
          verdicts[i] = "unapplied";
          continue;
        }
        fs.writeFileSync(file, mutated);
        try {
          const result = await exec(FORGE, args, ws, env);
          if (result.code === 0) {
            verdicts[i] = "survived";
          } else {
            verdicts[i] = /Compiler run failed|Compilation failed/.test(result.stdout + result.stderr)
              ? "invalid"
              : "killed";
          }
        } finally {
          fs.writeFileSync(file, original);
        }
      }
    })
  );
  return verdicts;
}
