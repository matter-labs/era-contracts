#!/usr/bin/env node
// SPDX-License-Identifier: MIT
"use strict";

/**
 * Atomic-interop mutation testing CLI.
 *
 *   node test/mutation/mutate.js generate   # parse targets, emit out/mutants.json
 *   node test/mutation/mutate.js run        # apply each mutant, build+test, emit out/results.json (resumable)
 *   node test/mutation/mutate.js report     # render out/report.md from results
 *   node test/mutation/mutate.js all        # generate + run + report
 *
 * Classification per mutant:
 *   UNCOMPILABLE  the mutated source fails to compile -> excluded from the score (standard practice:
 *                 the compiler, not the tests, caught it)
 *   KILLED        compiles, and at least one kill-signal test fails
 *   SURVIVED      compiles, and all kill-signal tests pass -> a test gap (or an equivalent mutant)
 *
 * Mutation score = KILLED / (KILLED + SURVIVED).
 *
 * The runner mutates one file at a time in place and always restores it (even on crash / SIGINT),
 * so the working tree is left clean.
 */

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const cfg = require("./config");
const { generateCandidates, functionRanges, offsetToLine } = require("./operators");

function ensureOutDir() {
  const dir = path.dirname(cfg.MUTANTS_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function readJson(file, fallback) {
  if (!fs.existsSync(file)) return fallback;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file, obj) {
  fs.writeFileSync(file, JSON.stringify(obj, null, 2));
}

// ------------------------------------------------------------------------------------------------
// generate
// ------------------------------------------------------------------------------------------------
function generate() {
  ensureOutDir();
  const mutants = [];
  let idCounter = 0;

  for (const target of cfg.TARGETS) {
    const abs = path.join(cfg.L1_DIR, target.file);
    const src = fs.readFileSync(abs, "utf8");

    let allowedRanges = null;
    if (target.functions && target.functions.length) {
      allowedRanges = functionRanges(src, target.functions);
      if (allowedRanges.length === 0) {
        console.warn(`WARN: no functions ${JSON.stringify(target.functions)} found in ${target.file}`);
      }
    }

    let candidates = generateCandidates(src, { swapGroups: cfg.SWAP_GROUPS });

    // Region filter for entry-point contracts.
    if (allowedRanges) {
      candidates = candidates.filter((c) => allowedRanges.some(([s, e]) => c.start >= s && c.end <= e));
    }

    // Dedupe by (start,end,replacement).
    const seen = new Set();
    for (const c of candidates) {
      const key = `${c.start}:${c.end}:${c.replacement}`;
      if (seen.has(key)) continue;
      seen.add(key);
      mutants.push({
        id: `M${String(++idCounter).padStart(4, "0")}`,
        file: target.file,
        tier: target.tier,
        line: offsetToLine(src, c.start),
        operator: c.operator,
        description: c.description,
        start: c.start,
        end: c.end,
        orig: c.orig,
        replacement: c.replacement,
      });
    }
  }

  writeJson(cfg.MUTANTS_FILE, mutants);

  // Summary by file/operator.
  const byFile = {};
  const byOp = {};
  for (const m of mutants) {
    byFile[m.file] = (byFile[m.file] || 0) + 1;
    byOp[m.operator] = (byOp[m.operator] || 0) + 1;
  }
  console.log(`Generated ${mutants.length} mutants -> ${path.relative(cfg.L1_DIR, cfg.MUTANTS_FILE)}`);
  console.log("\nBy file:");
  for (const [f, n] of Object.entries(byFile).sort((a, b) => b[1] - a[1]))
    console.log(`  ${n.toString().padStart(4)}  ${f}`);
  console.log("\nBy operator:");
  for (const [o, n] of Object.entries(byOp).sort((a, b) => b[1] - a[1]))
    console.log(`  ${n.toString().padStart(4)}  ${o}`);
  return mutants;
}

// ------------------------------------------------------------------------------------------------
// run
// ------------------------------------------------------------------------------------------------
function forgeEnv() {
  const env = { ...process.env };
  if (cfg.FORGE_PATH_PREPEND) env.PATH = `${cfg.FORGE_PATH_PREPEND}:${env.PATH}`;
  // Mutating a common library (ChainBatchRootTree / IndexedMerkleTree) forces every dependent to
  // recompile. With the repo's `optimizer_runs = 9999999` that is minutes per mutant; disabling the
  // optimizer cuts a common-lib rebuild from ~5min to ~45s and is behaviour-preserving for the logic
  // tests used as the kill signal (the baseline gate re-verifies green before any mutation runs).
  if (cfg.FOUNDRY_OPTIMIZER_OFF) {
    env.FOUNDRY_OPTIMIZER = "false";
    env.FOUNDRY_OPTIMIZER_RUNS = "0";
  }
  return env;
}

function forgeBuild() {
  const r = spawnSync(cfg.FORGE_BIN, ["build"], {
    cwd: cfg.L1_DIR,
    env: forgeEnv(),
    encoding: "utf8",
    timeout: cfg.BUILD_TIMEOUT_MS,
    maxBuffer: 64 * 1024 * 1024,
  });
  return r;
}

function forgeTest() {
  const args = [
    "test",
    "--threads",
    "1",
    "--ffi",
    "--match-path",
    cfg.KILL_SIGNAL_MATCH_PATH,
    "--no-match-test",
    "test_DefaultUpgrade_MainnetFork",
  ];
  const r = spawnSync(cfg.FORGE_BIN, args, {
    cwd: cfg.L1_DIR,
    env: forgeEnv(),
    encoding: "utf8",
    timeout: cfg.TEST_TIMEOUT_MS,
    maxBuffer: 64 * 1024 * 1024,
  });
  return r;
}

/** Generate the diamond-selectors.toml fixture the integration test setUp reads. */
function ensureSelectors() {
  const selFile = path.join(cfg.L1_DIR, "script-out", "diamond-selectors.toml");
  if (fs.existsSync(selFile)) return;
  console.log("Generating diamond-selectors.toml fixture ...");
  const r = spawnSync(
    cfg.FORGE_BIN,
    ["script", "deploy-scripts/ctm/DeployCTM.s.sol:DeployCTMScript", "--sig", "saveDiamondSelectors()", "--ffi"],
    { cwd: cfg.L1_DIR, env: forgeEnv(), encoding: "utf8", timeout: cfg.BUILD_TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024 }
  );
  if (!fs.existsSync(selFile)) {
    console.error(r.stdout, r.stderr);
    throw new Error("failed to generate diamond-selectors.toml");
  }
}

function looksLikeCompileError(r) {
  const out = (r.stdout || "") + (r.stderr || "");
  return /Compiler run failed|Error \(\d+\)|error\[/.test(out);
}

function applyMutant(absFile, origSrc, mutant) {
  const mutated = origSrc.slice(0, mutant.start) + mutant.replacement + origSrc.slice(mutant.end + 1);
  fs.writeFileSync(absFile, mutated);
}

function run() {
  ensureOutDir();
  const mutants = readJson(cfg.MUTANTS_FILE, null);
  if (!mutants) throw new Error("no mutants.json — run `generate` first");

  const results = readJson(cfg.RESULTS_FILE, {});

  // --- Pre-flight: fixture + green baseline -----------------------------------------------------
  ensureSelectors();
  console.log("Baseline build ...");
  let r = forgeBuild();
  if (r.status !== 0) {
    console.error(r.stdout, r.stderr);
    throw new Error("baseline build failed — fix the tree before mutating");
  }
  console.log("Baseline test ...");
  r = forgeTest();
  if (r.status !== 0) {
    console.error((r.stdout || "").slice(-4000), (r.stderr || "").slice(-2000));
    throw new Error("baseline tests are not green — cannot trust kill signal");
  }
  console.log("Baseline green.\n");

  // Cache original sources; register cleanup so the tree is always restored.
  const originals = new Map();
  for (const t of cfg.TARGETS) {
    const abs = path.join(cfg.L1_DIR, t.file);
    originals.set(t.file, { abs, src: fs.readFileSync(abs, "utf8") });
  }
  let currentlyMutated = null;
  const restore = () => {
    if (currentlyMutated) {
      const o = originals.get(currentlyMutated);
      fs.writeFileSync(o.abs, o.src);
      currentlyMutated = null;
    }
  };
  process.on("exit", restore);
  // Restore the tree on any external termination signal (the harness caps a single background call,
  // so chunked runs are terminated with SIGTERM/SIGINT). Without this a hard kill leaves a mutant in
  // place. The run is resumable, so exiting mid-chunk only costs the in-flight mutant.
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => {
      restore();
      process.exit(130);
    });
  }

  // Self-imposed wall-clock budget so a chunk exits gracefully (restoring the tree, flushing results)
  // before any external cap. Re-invoke `run` to continue — already-classified mutants are skipped.
  const maxSeconds = parseInt(process.env.MUT_MAX_SECONDS || "540", 10);

  const todo = mutants.filter((m) => !results[m.id]);
  console.log(`${mutants.length} mutants total, ${todo.length} remaining (budget ${maxSeconds}s this chunk).\n`);

  const t0 = Date.now();
  let done = 0;
  for (const m of todo) {
    if ((Date.now() - t0) / 1000 > maxSeconds) {
      console.log(
        `\nTime budget reached — ${done} done this chunk, ${todo.length - done} still remaining. Re-run to continue.`
      );
      break;
    }
    const o = originals.get(m.file);
    currentlyMutated = m.file;
    applyMutant(o.abs, o.src, m);

    let status, detail;
    const b = forgeBuild();
    if (b.error && b.error.code === "ETIMEDOUT") {
      status = "UNCOMPILABLE";
      detail = "build timeout";
    } else if (b.status !== 0) {
      status = "UNCOMPILABLE";
      detail = looksLikeCompileError(b) ? "compile error" : `build exit ${b.status}`;
    } else {
      const tr = forgeTest();
      if (tr.error && tr.error.code === "ETIMEDOUT") {
        // Mutation caused non-termination the tests trigger — that is a detected divergence.
        status = "KILLED";
        detail = "test timeout";
      } else if (tr.status !== 0) {
        status = "KILLED";
        detail = failureLine(tr);
      } else {
        status = "SURVIVED";
        detail = "all kill-signal tests passed";
      }
    }

    // Restore immediately.
    fs.writeFileSync(o.abs, o.src);
    currentlyMutated = null;

    results[m.id] = { status, detail, at: new Date().toISOString() };
    writeJson(cfg.RESULTS_FILE, results);

    done++;
    const elapsed = (Date.now() - t0) / 1000;
    const rate = elapsed / done;
    const eta = Math.round(rate * (todo.length - done));
    const tag = status === "SURVIVED" ? "SURVIVED  <<<" : status;
    console.log(
      `[${done}/${todo.length}] ${m.id} ${m.file.split("/").pop()}:${m.line} ${m.operator} ${tag} (${detail}) ` +
        `eta ${eta}s`
    );
  }

  restore();
  summarize(mutants, results);
}

/** Extract a compact failure descriptor from forge test output. */
function failureLine(r) {
  const out = (r.stdout || "") + "\n" + (r.stderr || "");
  const m = out.match(/\[FAIL[^\]]*\]\s*([^\n(]+)/);
  if (m) return "FAIL " + m[1].trim().slice(0, 80);
  const c = out.match(/(\d+) failed/);
  if (c) return `${c[1]} test(s) failed`;
  return `test exit ${r.status}`;
}

// ------------------------------------------------------------------------------------------------
// report
// ------------------------------------------------------------------------------------------------
function summarize(mutants, results) {
  const rows = mutants.map((m) => ({ ...m, ...(results[m.id] || { status: "PENDING" }) }));
  const counts = { KILLED: 0, SURVIVED: 0, UNCOMPILABLE: 0, PENDING: 0 };
  for (const r of rows) counts[r.status] = (counts[r.status] || 0) + 1;
  const scored = counts.KILLED + counts.SURVIVED;
  const score = scored ? ((counts.KILLED / scored) * 100).toFixed(1) : "n/a";
  console.log("\n==================== MUTATION SUMMARY ====================");
  console.log(`  killed:       ${counts.KILLED}`);
  console.log(`  survived:     ${counts.SURVIVED}`);
  console.log(`  uncompilable: ${counts.UNCOMPILABLE} (excluded)`);
  if (counts.PENDING) console.log(`  pending:      ${counts.PENDING}`);
  console.log(`  MUTATION SCORE: ${score}%  (killed / (killed+survived))`);
  console.log("==========================================================");
  return { rows, counts, score };
}

function report() {
  const mutants = readJson(cfg.MUTANTS_FILE, null);
  if (!mutants) throw new Error("no mutants.json — run `generate` first");
  const results = readJson(cfg.RESULTS_FILE, {});
  const { rows, counts, score } = summarize(mutants, results);

  const tierAgg = {};
  const fileAgg = {};
  const opAgg = {};
  const bump = (agg, key, status) => {
    agg[key] = agg[key] || { KILLED: 0, SURVIVED: 0, UNCOMPILABLE: 0, PENDING: 0 };
    agg[key][status]++;
  };
  for (const r of rows) {
    bump(tierAgg, r.tier, r.status);
    bump(fileAgg, r.file, r.status);
    bump(opAgg, r.operator, r.status);
  }
  const scoreOf = (a) => {
    const s = a.KILLED + a.SURVIVED;
    return s ? ((a.KILLED / s) * 100).toFixed(1) + "%" : "n/a";
  };

  const L = [];
  L.push("# Atomic-Interop Mutation Testing Report");
  L.push("");
  L.push(`Kill signal: \`forge test --match-path '${cfg.KILL_SIGNAL_MATCH_PATH}'\``);
  L.push("");
  L.push("A mutant is **killed** when at least one atomicity-focused test fails against it, and");
  L.push("**survived** when the whole kill-signal suite still passes. Uncompilable mutants (the change");
  L.push("is rejected by the compiler, not the tests) are excluded from the score, per standard practice.");
  L.push("");
  L.push("## Overall");
  L.push("");
  L.push(`| metric | value |`);
  L.push(`| --- | --- |`);
  L.push(`| **mutation score** | **${score}%** |`);
  L.push(`| killed | ${counts.KILLED} |`);
  L.push(`| survived | ${counts.SURVIVED} |`);
  L.push(`| uncompilable (excluded) | ${counts.UNCOMPILABLE} |`);
  if (counts.PENDING) L.push(`| pending | ${counts.PENDING} |`);
  L.push(`| total mutants | ${mutants.length} |`);
  L.push("");

  L.push("## Score by tier");
  L.push("");
  L.push("| tier | score | killed | survived | uncompilable |");
  L.push("| --- | --- | --- | --- | --- |");
  for (const [k, a] of Object.entries(tierAgg)) {
    L.push(`| ${k} | ${scoreOf(a)} | ${a.KILLED} | ${a.SURVIVED} | ${a.UNCOMPILABLE} |`);
  }
  L.push("");

  L.push("## Score by file");
  L.push("");
  L.push("| file | score | killed | survived | uncompilable |");
  L.push("| --- | --- | --- | --- | --- |");
  for (const [k, a] of Object.entries(fileAgg).sort((x, y) => scoreNum(x[1]) - scoreNum(y[1]))) {
    L.push(`| \`${k.split("/").pop()}\` | ${scoreOf(a)} | ${a.KILLED} | ${a.SURVIVED} | ${a.UNCOMPILABLE} |`);
  }
  L.push("");

  L.push("## Score by operator");
  L.push("");
  L.push("| operator | score | killed | survived | uncompilable |");
  L.push("| --- | --- | --- | --- | --- |");
  for (const [k, a] of Object.entries(opAgg)) {
    L.push(`| ${k} | ${scoreOf(a)} | ${a.KILLED} | ${a.SURVIVED} | ${a.UNCOMPILABLE} |`);
  }
  L.push("");

  const survivors = rows.filter((r) => r.status === "SURVIVED");
  L.push(`## Survivors (${survivors.length})`);
  L.push("");
  if (survivors.length === 0) {
    L.push("None — every compilable mutant was caught. 🎉");
  } else {
    L.push("Each survivor is a mutation the atomicity tests did **not** catch. Review each as either a");
    L.push("test gap to close or an equivalent mutant (semantically identical to the original).");
    L.push("");
    L.push("| id | file:line | operator | mutation |");
    L.push("| --- | --- | --- | --- |");
    for (const s of survivors) {
      const mut = `\`${truncate(s.orig)}\` → \`${truncate(s.replacement)}\``;
      L.push(`| ${s.id} | \`${s.file.split("/").pop()}:${s.line}\` | ${s.operator} | ${s.description}: ${mut} |`);
    }
  }
  L.push("");

  fs.writeFileSync(cfg.REPORT_FILE, L.join("\n"));
  console.log(`\nReport written -> ${path.relative(cfg.L1_DIR, cfg.REPORT_FILE)}`);
}

function scoreNum(a) {
  const s = a.KILLED + a.SURVIVED;
  return s ? (a.KILLED / s) * 100 : 999;
}
function truncate(s) {
  s = (s || "").replace(/\n/g, " ⏎ ").replace(/\s+/g, " ").trim();
  if (s === "") return "∅";
  return s.length > 48 ? s.slice(0, 45) + "..." : s;
}

// ------------------------------------------------------------------------------------------------
// main
// ------------------------------------------------------------------------------------------------
const cmd = process.argv[2] || "all";
try {
  if (cmd === "generate") generate();
  else if (cmd === "run") run();
  else if (cmd === "report") report();
  else if (cmd === "all") {
    generate();
    run();
    report();
  } else {
    console.error(`unknown command: ${cmd}\nusage: mutate.js [generate|run|report|all]`);
    process.exit(2);
  }
} catch (e) {
  console.error("ERROR:", e.message);
  process.exit(1);
}
