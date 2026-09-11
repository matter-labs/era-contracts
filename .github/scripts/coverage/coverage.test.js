/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires -- Runs directly in Node. */

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const { test } = require("node:test");
const { restoreBaseline } = require("./plan");

const BASE_SHA = "a".repeat(40);
const PR_SHA = "b".repeat(40);
const WORKFLOW = ".github/workflows/l1-contracts-ci.yaml";
const INTEROP = "l1-contracts/test/anvil-interop";
const SUCCESS = Object.fromEntries(
  ["plan", "build", "coverage-foundry", "coverage-anvil", "coverage-merge"].map((_name) => [
    _name,
    { result: "success" },
  ])
);
const lcov = (_hit, _found) => `SF:contracts/Test.sol\nLH:${_hit}\nLF:${_found}\nend_of_record\n`;

function temporaryDirectory(_t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "coverage-test-"));
  _t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
}

function plannerFixture(_t) {
  const directory = temporaryDirectory(_t);
  const root = path.join(directory, "repo");
  const write = (_file, _text) => {
    const target = path.join(root, _file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, _text);
  };
  for (const file of ["plan.js", "check.js"]) {
    write(`.github/scripts/coverage/${file}`, fs.readFileSync(path.join(__dirname, file)));
  }
  write(WORKFLOW, "name: Coverage\n");
  write(".nvmrc", "v20\n");
  write(".github/foundry-versions.env", "FOUNDRY_VERSION=v1.5.1\n");
  write("l1-contracts/package.json", JSON.stringify({ scripts: { "coverage:foundry": "forge coverage --threads 1" } }));
  write(
    "l1-contracts/foundry.toml",
    `[profile.default]\nremappings = [${JSON.stringify("system-contracts/=frozen-system-constants/")}]\n`
  );
  write(`${INTEROP}/src/coverage/lcov-generator.ts`, "// Excludes frozen constants.\nexport const enabled = true;\n");
  write(`${INTEROP}/src/core/utils.ts`, "export async function wait(tx, provider) { return await tx.wait(); }\n");
  write(`${INTEROP}/test/hardhat/01-base.spec.ts`, "");

  const git = (..._args) => execFileSync("git", _args, { cwd: root, encoding: "utf8" }).trim();
  git("init", "-q");
  git("config", "user.name", "Coverage fixture");
  git("config", "user.email", "coverage@example.invalid");
  git("config", "commit.gpgsign", "false");
  git("config", "core.hooksPath", path.join(directory, "no-hooks"));
  const commit = () => {
    git("add", ".");
    git("commit", "-qm", "fixture");
    return git("rev-parse", "HEAD");
  };
  const base = commit();

  const bin = path.join(directory, "bin");
  fs.mkdirSync(bin);
  fs.writeFileSync(
    path.join(bin, "gh"),
    `#!/usr/bin/env node
if (process.argv[2] !== "api") process.exit(1);
console.log(JSON.stringify(process.argv[3].includes("/actions/artifacts?") ? { artifacts: [] } : { workflow_runs: [] }));
`,
    { mode: 0o755 }
  );
  const plan = (_eventName = "pull_request", _source = git("rev-parse", "HEAD")) => {
    const event = path.join(directory, "event.json");
    const output = path.join(directory, "output");
    fs.writeFileSync(event, JSON.stringify({ pull_request: { base: { sha: base } }, inputs: { source_sha: _source } }));
    fs.writeFileSync(output, "");
    const result = spawnSync(process.execPath, [path.join(root, ".github/scripts/coverage/plan.js")], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}${path.delimiter}${process.env.PATH}`,
        GITHUB_REPOSITORY: "example/contracts",
        GITHUB_EVENT_NAME: _eventName,
        GITHUB_EVENT_PATH: event,
        GITHUB_OUTPUT: output,
        GITHUB_SHA: git("rev-parse", "HEAD"),
        RUNNER_TEMP: directory,
      },
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return Object.fromEntries(
      fs
        .readFileSync(output, "utf8")
        .trim()
        .split("\n")
        .map((_line) => {
          const separator = _line.indexOf("=");
          return [_line.slice(0, separator), _line.slice(separator + 1)];
        })
    );
  };
  return { write, commit, base, plan };
}

test("comment, remapping and receipt-wait edits still measure the exact base and PR", (_t) => {
  const fixture = plannerFixture(_t);
  const edits = [
    [`${INTEROP}/src/coverage/lcov-generator.ts`, "// Excludes tests and libraries.\nexport const enabled = true;\n"],
    ["l1-contracts/foundry.toml", "[profile.default]\nremappings = []\n"],
    [
      `${INTEROP}/src/core/utils.ts`,
      "export async function wait(tx, provider) { return await provider.waitForTransaction(tx.hash, 1); }\n",
    ],
  ];
  for (const [file, content] of edits) {
    fixture.write(file, content);
    const head = fixture.commit();
    const output = fixture.plan();
    assert.equal(output.cached, "false");
    assert.deepEqual(JSON.parse(output.revisions), [
      { kind: "pr", sha: head },
      { kind: "base", sha: fixture.base },
    ]);
  }
});

test("each revision discovers its own tests", (_t) => {
  const fixture = plannerFixture(_t);
  fixture.write(`${INTEROP}/test/hardhat/02-added.spec.ts`, "");
  fixture.commit();
  const { include } = JSON.parse(fixture.plan().anvil);
  assert.equal(include.filter((_group) => _group.kind === "base").length, 1);
  assert.equal(include.filter((_group) => _group.kind === "pr").length, 2);
});

test("manual regeneration accepts an exact source with different helper code", (_t) => {
  const fixture = plannerFixture(_t);
  fixture.write(`${INTEROP}/src/core/utils.ts`, "export const changed = true;\n");
  fixture.commit();
  const output = fixture.plan("workflow_dispatch", fixture.base);
  assert.deepEqual(JSON.parse(output.revisions), [{ kind: "base", sha: fixture.base }]);
});

test("a valid baseline from a successful upstream push remains reusable", async (_t) => {
  const directory = temporaryDirectory(_t);
  const repo = "example/contracts";
  const recipe = "recipe";
  const cached = await restoreBaseline(
    { sha: BASE_SHA, recipe, repo, directory },
    {
      api: (_endpoint) =>
        _endpoint.startsWith("actions/artifacts?")
          ? { artifacts: [{ id: 1, name: `coverage-baseline-${BASE_SHA}-${recipe}`, workflow_run: { id: 2 } }] }
          : {
              id: 2,
              repository: { full_name: repo },
              head_repository: { full_name: repo },
              path: WORKFLOW,
              event: "push",
              head_sha: BASE_SHA,
              status: "completed",
              conclusion: "success",
            },
      download: (_run, _name, _destination) => {
        assert.equal(_run, 2);
        assert.equal(_name, `coverage-baseline-${BASE_SHA}-${recipe}`);
        fs.mkdirSync(_destination, { recursive: true });
        fs.writeFileSync(path.join(_destination, "merged-lcov.info"), lcov(80, 100));
      },
      pause: () => assert.fail("A valid cached baseline must not wait"),
      now: () => 0,
      warn: (_message) => assert.fail(_message),
    }
  );
  assert.equal(cached, true);
});

const reportCases = [
  { name: "equal coverage passes", base: lcov(80, 100), pr: lcov(160, 200), status: 0 },
  { name: "increased coverage passes", base: lcov(80, 100), pr: lcov(81, 100), status: 0 },
  {
    name: "a decrease below displayed precision still fails",
    base: lcov(8000000, 10000000),
    pr: lcov(7999999, 10000000),
    status: 1,
  },
  { name: "missing baseline fails", pr: lcov(80, 100), status: 2 },
  { name: "invalid line totals fail", base: lcov(80, 100), pr: lcov(101, 100), status: 2 },
  {
    name: "failed coverage job fails",
    base: lcov(80, 100),
    pr: lcov(90, 100),
    results: { ...SUCCESS, "coverage-anvil": { result: "failure" } },
    status: 2,
  },
  { name: "failed artifact download fails", base: lcov(80, 100), pr: lcov(90, 100), ready: "false", status: 2 },
];
for (const scenario of reportCases) {
  test(scenario.name, (_t) => {
    const directory = temporaryDirectory(_t);
    const base = path.join(directory, "base.info");
    const pr = path.join(directory, "pr.info");
    if (scenario.base) fs.writeFileSync(base, scenario.base);
    if (scenario.pr) fs.writeFileSync(pr, scenario.pr);
    const result = spawnSync(process.execPath, [path.join(__dirname, "check.js"), base, pr], {
      encoding: "utf8",
      env: {
        ...process.env,
        BASE_SHA,
        PR_SHA,
        COVERAGE_RESULTS: JSON.stringify(scenario.results || SUCCESS),
        COVERAGE_INPUTS_READY: scenario.ready || "true",
        GITHUB_STEP_SUMMARY: path.join(directory, "summary.md"),
      },
    });
    assert.equal(result.status, scenario.status, result.stderr || result.stdout);
    assert.match(
      fs.readFileSync(path.join(directory, "summary.md"), "utf8"),
      scenario.status === 0
        ? /Passed: combined line coverage did not decrease/
        : scenario.status === 1
          ? /Failed: combined line coverage decreased/
          : /Unavailable: no regression decision was made/
    );
  });
}
