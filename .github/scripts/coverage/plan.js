/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Runs directly in Node. */

const fs = require("node:fs");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { execFileSync } = require("node:child_process");
const { totals } = require("./check");

const ROOT = path.resolve(__dirname, "../../..");
const WORKFLOW = ".github/workflows/l1-contracts-ci.yaml";
const SPEC_DIRECTORY = "l1-contracts/test/anvil-interop/test/hardhat";
const RECIPE_FILES = [WORKFLOW, ".github/scripts/coverage/plan.js", ".nvmrc", ".github/foundry-versions.env"];
// These run from the measured checkout; workflow-level pins and the Foundry command are shared.
// Test discovery, deployment fixtures and dependencies remain revision-specific.
const MEASUREMENT_PATHS = [
  "da-contracts/foundry.toml",
  "l1-contracts/foundry.toml",
  "l1-contracts/hardhat.config.ts",
  "l1-contracts/remappings.txt",
  "l1-contracts/tsconfig.json",
  "l1-contracts/scripts/merge-coverage.ts",
  "l1-contracts/test/anvil-interop/tsconfig.json",
  "l1-contracts/test/anvil-interop/run-coverage.ts",
  "l1-contracts/test/anvil-interop/merge-shard-lcov.ts",
  "l1-contracts/test/anvil-interop/src/coverage/",
  "l1-contracts/test/anvil-interop/src/core/utils.ts",
  "l1-contracts/test/anvil-interop/src/daemons/anvil-manager.ts",
];
const MEASUREMENT_SCRIPTS = {
  "da-contracts/package.json": ["build:foundry"],
  "l1-contracts/package.json": ["build:foundry", "coverage:merge"],
  "l1-contracts/test/anvil-interop/package.json": ["merge:shards"],
};
const SHA = /^[a-f0-9]{40}$/;
const GROUP_COUNT = 2;
const WAIT_MS = 120000;
const POLL_MS = 15000;

function coverageCommand(_read) {
  const command = JSON.parse(_read("l1-contracts/package.json")).scripts?.["coverage:foundry"];
  if (typeof command !== "string" || !/^forge coverage ./.test(command) || /[\r\n\0]/.test(command)) {
    throw new Error("coverage:foundry must be a single-line forge coverage command");
  }
  return command;
}

function recipeHash(_read, _coverageCommand = coverageCommand(_read)) {
  const hash = createHash("sha256");
  for (const file of RECIPE_FILES) {
    hash.update(file).update("\0").update(_read(file)).update("\0");
  }
  hash.update("coverage:foundry\0").update(_coverageCommand).update("\0");
  return hash.digest("hex");
}

function toolingChanges(_git, _base, _head) {
  const changed = _git("diff", "--name-only", "--no-renames", "-z", _base, _head, "--", ...MEASUREMENT_PATHS)
    .split("\0")
    .filter(Boolean);
  for (const [file, names] of Object.entries(MEASUREMENT_SCRIPTS)) {
    const base = JSON.parse(_git("show", `${_base}:${file}`)).scripts;
    const head = JSON.parse(_git("show", `${_head}:${file}`)).scripts;
    for (const name of names) {
      if (base?.[name] !== head?.[name]) {
        changed.push(`${file} (${name})`);
      }
    }
  }
  return changed;
}

function sourceRevisions(_eventName, _event, _sha) {
  const source = _eventName === "workflow_dispatch" ? _event.inputs?.source_sha || _sha : _sha;
  const base = _eventName === "pull_request" ? _event.pull_request?.base?.sha : source;
  if (!["pull_request", "push", "workflow_dispatch"].includes(_eventName) || !SHA.test(source) || !SHA.test(base)) {
    throw new Error("Coverage requires a supported event and full, exact source/base commit SHAs");
  }
  return {
    base_sha: base,
    pr_sha: _eventName === "pull_request" ? source : "",
    revisions: [{ kind: _eventName === "pull_request" ? "pr" : "base", sha: source }],
  };
}

function groupSpecs(_revision, _names) {
  const specs = _names.filter((name) => /^\d+-.*\.spec\.ts$/.test(name)).sort();
  if (!specs.length || specs.some((name) => !/^\d+[0-9A-Za-z._-]*\.spec\.ts$/.test(name))) {
    throw new Error(`No specs or unsafe spec names at ${_revision.sha}`);
  }
  return Array.from({ length: Math.min(GROUP_COUNT, specs.length) }, (_, index) => ({
    ..._revision,
    group: `group-${index + 1}`,
    specs: specs.filter((_, i) => i % GROUP_COUNT === index).join(" "),
  }));
}

function trustedRun(_run, _repo, _sha, _pending = false) {
  return (
    _run.repository?.full_name?.toLowerCase() === _repo.toLowerCase() &&
    _run.head_repository?.full_name?.toLowerCase() === _repo.toLowerCase() &&
    _run.path?.split("@")[0] === WORKFLOW &&
    (_pending
      ? _run.event === "push" && ["queued", "in_progress", "waiting", "pending", "requested"].includes(_run.status)
      : ["push", "workflow_dispatch"].includes(_run.event) &&
        _run.status === "completed" &&
        _run.conclusion === "success") &&
    (_run.event === "workflow_dispatch" || _run.head_sha === _sha)
  );
}

async function restoreBaseline(_request, _services) {
  const { sha, recipe, repo, directory } = _request;
  const { api, download, pause, now, warn, matchingRecipe } = _services;
  const deadline = now() + WAIT_MS;
  const name = `coverage-baseline-${sha}-${recipe}`;
  const attempted = new Set();
  try {
    while (now() <= deadline) {
      const { artifacts } = api(`actions/artifacts?name=${name}&per_page=100`);
      for (const artifact of artifacts) {
        if (artifact.name !== name || artifact.expired || !artifact.workflow_run?.id || attempted.has(artifact.id)) {
          continue;
        }
        const run = api(`actions/runs/${artifact.workflow_run.id}`);
        if (!trustedRun(run, repo, sha)) {
          continue;
        }
        attempted.add(artifact.id);
        try {
          fs.rmSync(directory, { recursive: true, force: true });
          download(run.id, name, directory);
          const metadata = JSON.parse(fs.readFileSync(path.join(directory, "metadata.json"), "utf8"));
          if (metadata.sha !== sha || metadata.recipe !== recipe) {
            throw new Error("Source SHA or coverage recipe does not match");
          }
          totals(fs.readFileSync(path.join(directory, "merged-lcov.info"), "utf8"));
          console.log(`Reusing coverage for ${sha} from run ${run.id}`);
          return true;
        } catch (error) {
          warn(`Ignoring unavailable or invalid coverage artifact ${artifact.id}: ${error.message}`);
        }
      }
      if (now() >= deadline) {
        break;
      }
      const { workflow_runs: runs } = api(
        `actions/workflows/l1-contracts-ci.yaml/runs?event=push&head_sha=${sha}&per_page=100`
      );
      if (!runs.some((run) => trustedRun(run, repo, sha, true)) || !matchingRecipe(sha, recipe)) {
        break;
      }
      console.log(`Baseline ${sha} is being generated; waiting for its report`);
      await pause(Math.min(POLL_MS, deadline - now()));
    }
  } catch (error) {
    warn(`Baseline lookup unavailable: ${error.message}`);
  }
  fs.rmSync(directory, { recursive: true, force: true });
  console.log(`Generating missing coverage for exact base ${sha} in this run`);
  return false;
}

async function main() {
  const env = process.env;
  if (!env.GITHUB_REPOSITORY || !env.GITHUB_EVENT_PATH || !env.GITHUB_OUTPUT || !env.RUNNER_TEMP) {
    throw new Error("Coverage planning requires the GitHub Actions event, repository, output and runner paths");
  }
  const execute = (command, args) =>
    execFileSync(command, args, { cwd: ROOT, encoding: "utf8", maxBuffer: 10 * 1024 * 1024 });
  const git = (...args) => execute("git", args);
  const gh = (...args) => execute("gh", args);
  const read = (file) => fs.readFileSync(path.join(ROOT, file), "utf8");
  const plan = sourceRevisions(
    env.GITHUB_EVENT_NAME,
    JSON.parse(fs.readFileSync(env.GITHUB_EVENT_PATH)),
    env.GITHUB_SHA
  );
  const command = coverageCommand(read);
  const recipe = recipeHash(read, command);
  const nodeVersion = read(".nvmrc").trim();
  const foundryVersion = /^FOUNDRY_VERSION=([A-Za-z0-9._-]+)\r?$/m.exec(read(".github/foundry-versions.env"))?.[1];
  if (!/^[A-Za-z0-9.*_/-]+$/.test(nodeVersion) || !foundryVersion) {
    throw new Error("Invalid Node or Foundry version pin");
  }
  const ensureCommit = (sha) => {
    try {
      git("cat-file", "-e", `${sha}^{commit}`);
    } catch {
      git("fetch", "--no-tags", "--depth=1", "origin", sha);
    }
  };
  const directory = path.join(env.RUNNER_TEMP, "coverage-base");
  ensureCommit(plan.base_sha);
  const changes = toolingChanges(git, plan.base_sha, env.GITHUB_SHA);
  if (changes.length && !plan.pr_sha) {
    throw new Error(
      `Coverage unavailable: requested source uses different measurement tooling: ${changes.join(", ")}. ` +
        "Select a workflow ref with matching measurement tooling."
    );
  }
  let cached = false;
  if (plan.pr_sha && !changes.length) {
    cached = await restoreBaseline(
      { sha: plan.base_sha, recipe, repo: env.GITHUB_REPOSITORY, directory },
      {
        api: (endpoint) => JSON.parse(gh("api", `repos/${env.GITHUB_REPOSITORY}/${endpoint}`)),
        download: (run, name, destination) =>
          gh("run", "download", String(run), "--repo", env.GITHUB_REPOSITORY, "--name", name, "--dir", destination),
        pause: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
        now: Date.now,
        warn: (message) => console.warn(`::warning::${message}`),
        matchingRecipe: (sha, expected) => {
          ensureCommit(sha);
          return recipeHash((file) => git("show", `${sha}:${file}`)) === expected;
        },
      }
    );
    if (!cached) {
      plan.revisions.push({ kind: "base", sha: plan.base_sha });
    }
  }
  const anvil = plan.revisions.flatMap((revision) => {
    ensureCommit(revision.sha);
    return groupSpecs(revision, git("ls-tree", "-z", "--name-only", `${revision.sha}:${SPEC_DIRECTORY}`).split("\0"));
  });
  const outputs = {
    ...plan,
    tooling_changes: JSON.stringify(changes),
    revisions: JSON.stringify(plan.revisions),
    anvil: JSON.stringify({ include: anvil }),
    recipe,
    cached: String(cached),
    baseline_path: directory,
    node_version: nodeVersion,
    foundry_version: foundryVersion,
    coverage_command: command,
  };
  fs.appendFileSync(
    env.GITHUB_OUTPUT,
    Object.entries(outputs)
      .map(([key, value]) => `${key}=${value}\n`)
      .join("")
  );
  console.log(`Coverage revisions: ${outputs.revisions}`);
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`Coverage planning failed: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  sourceRevisions,
  groupSpecs,
  trustedRun,
  restoreBaseline,
  recipeHash,
  coverageCommand,
  toolingChanges,
};
