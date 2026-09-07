/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Tests the Node entry point. */

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { test } = require("node:test");
const { sourceRevisions, groupSpecs, trustedRun, restoreBaseline, recipeHash, coverageCommand } = require("./plan");

const BASE = "a".repeat(40);
const PR = "b".repeat(40);
const RECIPE = "c".repeat(64);
const REPO = "matter-labs/era-contracts";
const NAME = `coverage-baseline-${BASE}-${RECIPE}`;
const ARTIFACT = { id: 1, name: NAME, expired: false, workflow_run: { id: 2 } };
const RUN = {
  id: 2,
  repository: { full_name: REPO },
  head_repository: { full_name: REPO },
  path: ".github/workflows/l1-contracts-ci.yaml",
  event: "push",
  head_sha: BASE,
  status: "completed",
  conclusion: "success",
};

function fixture(_t, _overrides = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "coverage-plan-test-"));
  _t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const state = { time: 0, downloads: 0, warnings: [], endpoints: [] };
  const services = {
    api: (endpoint) => {
      state.endpoints.push(endpoint);
      if (endpoint.startsWith("actions/artifacts?")) {
        return { artifacts: [ARTIFACT] };
      }
      if (endpoint.startsWith("actions/workflows/")) {
        return { workflow_runs: [] };
      }
      return RUN;
    },
    download: (run, name, destination) => {
      state.downloads++;
      assert.equal(run, RUN.id);
      assert.equal(name, NAME);
      fs.mkdirSync(destination, { recursive: true });
      fs.writeFileSync(path.join(destination, "metadata.json"), JSON.stringify({ sha: BASE, recipe: RECIPE }));
      fs.writeFileSync(path.join(destination, "merged-lcov.info"), "SF:contracts/C.sol\nLF:10\nLH:9\nend_of_record\n");
    },
    pause: async (ms) => {
      state.time += ms;
    },
    now: () => state.time,
    warn: (message) => state.warnings.push(message),
    matchingRecipe: () => true,
    ..._overrides,
  };
  return { request: { sha: BASE, recipe: RECIPE, repo: REPO, directory }, services, state };
}

test("PR planning uses its exact base and tested merge, not the PR head or branch name", () => {
  const plan = sourceRevisions(
    "pull_request",
    { pull_request: { base: { sha: BASE }, head: { sha: "d".repeat(40) } } },
    PR
  );
  assert.deepEqual(plan, { base_sha: BASE, pr_sha: PR, revisions: [{ kind: "pr", sha: PR }] });
});

test("direct pushes and manual historical regeneration need no associated PR", () => {
  for (const plan of [
    sourceRevisions("push", {}, BASE),
    sourceRevisions("workflow_dispatch", { inputs: { source_sha: BASE } }, PR),
    sourceRevisions("workflow_dispatch", { inputs: { source_sha: "" } }, BASE),
  ]) {
    assert.deepEqual(plan, { base_sha: BASE, pr_sha: "", revisions: [{ kind: "base", sha: BASE }] });
  }
  assert.throws(() => sourceRevisions("workflow_dispatch", { inputs: { source_sha: "main" } }, PR));
  assert.throws(() => sourceRevisions("pull_request", { pull_request: { base: { sha: "abc" } } }, PR));
  assert.throws(() => sourceRevisions("repository_dispatch", {}, BASE));
});

test("Anvil grouping covers each revision's sorted specs exactly once with safe shell arguments", () => {
  const revision = { kind: "base", sha: BASE };
  const groups = groupSpecs(revision, ["03-three.spec.ts", "README.md", "01-one.spec.ts", "02-two.spec.ts"]);
  assert.deepEqual(groups, [
    { ...revision, group: "group-1", specs: "01-one.spec.ts 03-three.spec.ts" },
    { ...revision, group: "group-2", specs: "02-two.spec.ts" },
  ]);
  assert.equal(groupSpecs(revision, ["01-one.spec.ts"]).length, 1);
  assert.throws(() => groupSpecs(revision, []));
  assert.throws(() => groupSpecs(revision, ["01-one.spec.ts", "02-$(command).spec.ts"]));
});

test("the recipe tracks workflow, planner, pins and coverage command, ignoring other package fields", () => {
  const command = "forge coverage --threads 1";
  const read = (file) =>
    file === "l1-contracts/package.json" ? JSON.stringify({ scripts: { "coverage:foundry": command } }) : file;
  const recipe = recipeHash(read);
  for (const changed of ["l1-contracts-ci.yaml", "plan.js", ".nvmrc", "foundry-versions.env"]) {
    assert.notEqual(
      recipeHash((file) => read(file) + (file.endsWith(changed) ? "changed" : "")),
      recipe
    );
  }
  assert.notEqual(recipeHash(read, `${command} --no-match-coverage test`), recipe);
  assert.equal(
    recipeHash((file) =>
      file === "l1-contracts/package.json"
        ? JSON.stringify({ scripts: { "coverage:foundry": command }, unrelated: "changed" })
        : read(file)
    ),
    recipe
  );
});

test("the Foundry command preserves arguments and rejects missing, multiline or unrelated scripts", () => {
  const read = (command) => () => JSON.stringify({ scripts: { "coverage:foundry": command } });
  const command = "forge coverage --no-match-coverage 'contracts/Excluded.sol'";
  assert.equal(coverageCommand(read(command)), command);
  for (const invalid of [
    undefined,
    null,
    "",
    "yarn coverage",
    "forge coverage ",
    "forge coverage --ffi\nnext",
    "forge coverage --ffi\n",
    "forge coverage --ffi\r",
    "forge coverage --ffi\0",
  ]) {
    assert.throws(() => coverageCommand(read(invalid)), /single-line forge coverage/);
  }
});

test("only successful same-repository push/dispatch producers are trusted", () => {
  assert.equal(trustedRun(RUN, REPO, BASE), true);
  assert.equal(trustedRun({ ...RUN, event: "workflow_dispatch", head_sha: PR }, REPO, BASE), true);
  for (const change of [
    { event: "pull_request" },
    { head_sha: PR },
    { conclusion: "failure" },
    { status: "in_progress" },
    { head_repository: { full_name: "someone/fork" } },
    { repository: { full_name: "someone/other" } },
    { path: ".github/workflows/other.yaml" },
  ]) {
    assert.equal(trustedRun({ ...RUN, ...change }, REPO, BASE), false);
  }
});

test("retained exact-SHA/recipe coverage is downloaded and validated", async (t) => {
  const { request, services, state } = fixture(t);
  assert.equal(await restoreBaseline(request, services), true);
  assert.equal(state.downloads, 1);
  assert.equal(state.time, 0);
  assert.match(state.endpoints[0], new RegExp(`name=${NAME}&`));
  assert.ok(fs.existsSync(path.join(request.directory, "merged-lcov.info")));
});

test("missing, expired and PR-produced artifacts recover without waiting", async (t) => {
  for (const artifacts of [[], [{ ...ARTIFACT, expired: true }], [ARTIFACT]]) {
    const { request, services, state } = fixture(t, {
      api: (endpoint) =>
        endpoint.startsWith("actions/artifacts?")
          ? { artifacts }
          : endpoint.startsWith("actions/workflows/")
            ? { workflow_runs: [] }
            : { ...RUN, event: "pull_request" },
    });
    assert.equal(await restoreBaseline(request, services), false);
    assert.equal(state.downloads, 0);
    assert.equal(state.time, 0);
  }
});

test("wrong metadata and invalid coverage recover and discard the downloaded report", async (t) => {
  for (const change of [{ sha: PR, recipe: RECIPE }, { sha: BASE, recipe: "other" }, null]) {
    const { request, services, state } = fixture(t);
    const download = services.download;
    services.download = (...args) => {
      download(...args);
      fs.writeFileSync(
        path.join(request.directory, change ? "metadata.json" : "merged-lcov.info"),
        change ? JSON.stringify(change) : ""
      );
    };
    assert.equal(await restoreBaseline(request, services), false);
    assert.equal(state.warnings.length, 1);
    assert.equal(fs.existsSync(request.directory), false);
  }
});

test("a matching producer can finish while the planner waits", async (t) => {
  const { request, services, state } = fixture(t);
  services.api = (endpoint) => {
    if (endpoint.startsWith("actions/artifacts?")) {
      return { artifacts: state.time ? [ARTIFACT] : [] };
    }
    return endpoint.startsWith("actions/workflows/")
      ? { workflow_runs: [{ ...RUN, status: "in_progress", conclusion: null }] }
      : RUN;
  };
  assert.equal(await restoreBaseline(request, services), true);
  assert.equal(state.time, 15000);
  assert.equal(state.downloads, 1);
});

test("pending generation times out and a different recipe never delays recovery", async (t) => {
  for (const matching of [true, false]) {
    const { request, services, state } = fixture(t, {
      api: (endpoint) =>
        endpoint.startsWith("actions/artifacts?")
          ? { artifacts: [] }
          : { workflow_runs: [{ ...RUN, status: "in_progress", conclusion: null }] },
      matchingRecipe: () => matching,
    });
    assert.equal(await restoreBaseline(request, services), false);
    assert.equal(state.time, matching ? 120000 : 0);
  }
});

test("API failure is a warning and local recovery, not a coverage regression", async (t) => {
  const { request, services, state } = fixture(t, {
    api: () => {
      throw new Error("API unavailable");
    },
  });
  assert.equal(await restoreBaseline(request, services), false);
  assert.match(state.warnings[0], /lookup unavailable/);
  assert.equal(state.time, 0);
});

test("CLI outputs exact matrices for push, historical dispatch and PR recovery", (t) => {
  const { request } = fixture(t);
  const root = path.resolve(__dirname, "../../..");
  const git = (ref) => execFileSync("git", ["rev-parse", ref], { cwd: root, encoding: "utf8" }).trim();
  const head = git("HEAD");
  const base = git("HEAD^1");
  const eventPath = path.join(request.directory, "event.json");
  const outputPath = path.join(request.directory, "outputs");
  // The CLI must recover from an unavailable API without using the developer's GitHub credentials.
  fs.writeFileSync(path.join(request.directory, "gh"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  for (const eventName of ["push", "workflow_dispatch", "pull_request"]) {
    fs.writeFileSync(
      eventPath,
      JSON.stringify({ inputs: { source_sha: base }, pull_request: { base: { sha: base } } })
    );
    fs.writeFileSync(outputPath, "");
    execFileSync(process.execPath, [path.join(__dirname, "plan.js")], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${request.directory}${path.delimiter}${process.env.PATH}`,
        GITHUB_REPOSITORY: REPO,
        GITHUB_EVENT_NAME: eventName,
        GITHUB_EVENT_PATH: eventPath,
        GITHUB_SHA: head,
        GITHUB_OUTPUT: outputPath,
        RUNNER_TEMP: request.directory,
      },
    });
    const output = Object.fromEntries(
      fs
        .readFileSync(outputPath, "utf8")
        .trimEnd()
        .split("\n")
        .map((line) => {
          const index = line.indexOf("=");
          return [line.slice(0, index), line.slice(index + 1)];
        })
    );
    const expected =
      eventName === "pull_request"
        ? [
            { kind: "pr", sha: head },
            { kind: "base", sha: base },
          ]
        : [{ kind: "base", sha: eventName === "push" ? head : base }];
    assert.deepEqual(JSON.parse(output.revisions), expected);
    assert.equal(output.base_sha, eventName === "push" ? head : base);
    assert.equal(output.cached, "false");
    assert.equal(output.pr_sha, eventName === "pull_request" ? head : "");
    assert.equal(JSON.parse(output.anvil).include.length, expected.length * 2);
    assert.match(output.recipe, /^[a-f0-9]{64}$/);
    assert.ok(output.node_version && output.foundry_version);
    assert.equal(
      output.coverage_command,
      JSON.parse(fs.readFileSync(path.join(root, "l1-contracts/package.json"))).scripts["coverage:foundry"]
    );
  }
});
