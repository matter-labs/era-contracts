/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Runs directly in Node. */

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

function totals(_lcov) {
  // LCOV has already validated these reports in the existing filtering step.
  const fields = (name) => [..._lcov.matchAll(new RegExp(`^${name}:(\\d+)\\r?$`, "gm"))].map((m) => BigInt(m[1]));
  const hit = fields("LH");
  const found = fields("LF");
  if (!hit.length || hit.length !== found.length || hit.some((n, i) => n > found[i])) {
    throw new Error("Missing or inconsistent LCOV line totals");
  }
  const sum = (values) => values.reduce((a, b) => a + b, 0n);
  const result = { hit: sum(hit), found: sum(found) };
  if (result.found === 0n) {
    throw new Error("LCOV report has no instrumented lines");
  }
  return result;
}

function compare(_base, _pr) {
  return _pr.hit * _base.found - _base.hit * _pr.found;
}

function mergedPr(_pulls, _sha) {
  const pr = _pulls.find((p) => p.merged_at && p.merge_commit_sha === _sha);
  if (!pr) {
    throw new Error(`No merged PR produced base ${_sha}; its coverage baseline is unavailable`);
  }
  return pr;
}

function checkoutSha(_log) {
  const sha = /git log -1 --format=%H\r?\n[^\r\n]*\s([a-f0-9]{40})\r?(?:\n|$)/.exec(_log)?.[1];
  if (!sha) {
    throw new Error("Cannot identify the source revision of the historical coverage report");
  }
  return sha;
}

function main() {
  const { GITHUB_REPOSITORY: repo, BASE_SHA: baseSha } = process.env;
  if (!repo || !/^[a-f0-9]{40}$/.test(baseSha || "") || process.argv.length !== 3) {
    throw new Error("Set GITHUB_REPOSITORY and BASE_SHA, then run check.js <merged-lcov>");
  }
  const gh = (...args) => execFileSync("gh", args, { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 });
  const api = (endpoint) => JSON.parse(gh("api", `repos/${repo}/${endpoint}`));
  const pr = mergedPr(api(`commits/${baseSha}/pulls?per_page=100`), baseSha);
  const { workflow_runs: runs } = api(
    `actions/workflows/l1-contracts-ci.yaml/runs?event=pull_request&head_sha=${pr.head.sha}&status=completed&per_page=20`
  );
  const run = runs.find((r) =>
    api(`actions/runs/${r.id}/artifacts?name=coverage-reports`).artifacts.some((a) => !a.expired)
  );
  if (!run) {
    throw new Error(`No retained coverage report for merged PR #${pr.number}`);
  }
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "base-coverage-"));
  try {
    gh("run", "download", String(run.id), "--repo", repo, "--name", "coverage-reports", "--dir", directory);
    const treeFile = path.join(directory, "coverage/commit-tree");
    let tree;
    if (fs.existsSync(treeFile)) {
      tree = fs.readFileSync(treeFile, "utf8").trim();
    } else {
      // Reports predating commit-tree still record the actual merge checkout in the job log.
      // The run API's head_sha identifies the PR head, not that tested merge commit.
      const { jobs } = api(`actions/runs/${run.id}/jobs?per_page=100`);
      const job = jobs.find((j) => j.name === "coverage-report");
      if (!job?.steps.some((s) => s.name === "Filter merged coverage" && s.conclusion === "success")) {
        throw new Error("Historical coverage report was not successfully filtered");
      }
      const sha = checkoutSha(gh("api", `repos/${repo}/actions/jobs/${job.id}/logs`, "--allow-escape-sequences"));
      tree = api(`git/commits/${sha}`).tree.sha;
    }
    if (tree !== api(`git/commits/${baseSha}`).tree.sha) {
      throw new Error(`Coverage run ${run.id} measured a different source tree than base ${baseSha}`);
    }
    const base = totals(fs.readFileSync(path.join(directory, "coverage/merged-lcov.info"), "utf8"));
    const current = totals(fs.readFileSync(process.argv[2], "utf8"));
    const percent = (c) => (100 * Number(c.hit)) / Number(c.found);
    const difference = compare(base, current);
    const summary = [
      "## Coverage comparison",
      "",
      `Base: [${baseSha.slice(0, 12)}](${run.html_url}), from merged PR #${pr.number}.`,
      "",
      "| Revision | Covered / total lines | Coverage |",
      "| --- | ---: | ---: |",
      `| Base | ${base.hit} / ${base.found} | ${percent(base).toFixed(4)}% |`,
      `| PR | ${current.hit} / ${current.found} | ${percent(current).toFixed(4)}% |`,
      "",
      `Delta: ${(percent(current) - percent(base)).toFixed(4)} percentage points. Exact, unrounded ratios determine the result.`,
      "",
      difference < 0n
        ? "**Failed: combined line coverage decreased.**"
        : "**Passed: combined line coverage did not decrease.**",
    ].join("\n");
    console.log(summary);
    if (process.env.GITHUB_STEP_SUMMARY) {
      fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
    }
    process.exitCode = difference < 0n ? 1 : 0;
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`Coverage comparison failed: ${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = { totals, compare, mergedPr, checkoutSha };
