const assert = require("node:assert/strict");
const { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");

// protocol-ops.sh's docker mode, run against a scratch checkout with a stub `docker` that records
// the `docker run` it is handed: no daemon, image or network.
const STUB_DOCKER = `#!/usr/bin/env bash
case "$1 $2" in
  "image inspect")
    if [[ "$*" == *revision* ]]; then printf '%s\\n' "\${STUB_REVISION:-}"; exit 0; fi
    if [[ "$*" == *RepoDigests* ]]; then printf '%s\\n' "\${STUB_DIGEST:-}"; exit 0; fi
    [[ -f "$STUB_DIR/pulled" ]] ;;
  "pull --quiet")
    touch "$STUB_DIR/pulled"; echo "pull output" ;;
  run*)
    shift; printf '%s\\n' "$@" > "$STUB_DIR/run"; echo "container output" ;;
esac
`;

// Runs `fn` on a fresh scratch checkout, removed afterwards.
function withCheckout(fn) {
  const repo = mkdtempSync(join(tmpdir(), "protocol-ops-wrapper-"));
  copyFileSync(join(__dirname, "../../protocol-ops.sh"), join(repo, "protocol-ops.sh"));
  mkdirSync(join(repo, "l1-contracts/upgrade-envs/v1"), { recursive: true });
  writeFileSync(join(repo, "l1-contracts/upgrade-envs/v1/stage.toml"), "era_chain_id = 1\n");
  mkdirSync(join(repo, "protocol-ops"));
  mkdirSync(join(repo, "stub"));
  writeFileSync(join(repo, "stub/docker"), STUB_DOCKER, { mode: 0o755 });
  // Local mode's binary: a run that falls back to it, instead of the image, leaves a mark.
  writeFileSync(join(repo, "stub/protocol_ops"), 'touch "$STUB_DIR/local"\n', { mode: 0o755 });
  const git = (...args) => spawnSync("git", ["-C", repo, ...args], { encoding: "utf8" }).stdout.trim();
  git("init", "-q");
  git("add", "protocol-ops.sh", "l1-contracts");
  git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture");
  try {
    fn({ repo, head: git("rev-parse", "HEAD") });
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
}

function wrapper({ repo }, args, env = {}) {
  const result = spawnSync("bash", [join(repo, "protocol-ops.sh"), ...args], {
    encoding: "utf8",
    env: {
      PATH: `${join(repo, "stub")}:${process.env.PATH}`,
      HOME: process.env.HOME,
      STUB_DIR: join(repo, "stub"),
      PROTOCOL_OPS_BIN: join(repo, "stub/protocol_ops"),
      STUB_DIGEST: "ghcr.io/matter-labs/protocol-ops@sha256:abc",
      ...env,
    },
  });
  const run = join(repo, "stub/run");
  return { ...result, run: existsSync(run) ? readFileSync(run, "utf8").trim().split("\n") : null };
}

const UPGRADE_ENVS_MOUNT = (repo) => `${repo}/l1-contracts/upgrade-envs:/contracts/l1-contracts/upgrade-envs`;

test("a release run from a checkout of its revision mounts upgrade-envs/ and records the image", () => {
  withCheckout((fixture) => {
    const result = wrapper(fixture, ["--tag", "sha256:abc", "chain", "upgrade"], { STUB_REVISION: fixture.head });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "container output\n", "pull output must not reach stdout");
    assert.ok(result.run.includes(UPGRADE_ENVS_MOUNT(fixture.repo)));
    assert.ok(result.run.includes("PROTOCOL_OPS_IMAGE=ghcr.io/matter-labs/protocol-ops@sha256:abc"));
    assert.ok(result.run.includes("PROTOCOL_OPS_IMAGE_DIGEST=ghcr.io/matter-labs/protocol-ops@sha256:abc"));
    assert.deepEqual(result.run.slice(-4), [
      "ghcr.io/matter-labs/protocol-ops@sha256:abc",
      "protocol_ops",
      "chain",
      "upgrade",
    ]);
  });
});

test("outputs under output/ don't count as edits", () => {
  withCheckout((fixture) => {
    mkdirSync(join(fixture.repo, "l1-contracts/upgrade-envs/v1/output/stage"), { recursive: true });
    writeFileSync(join(fixture.repo, "l1-contracts/upgrade-envs/v1/output/stage/ecosystem.toml"), "");
    const result = wrapper(fixture, ["--tag", "t", "chain", "upgrade"], { STUB_REVISION: fixture.head });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.run.includes(UPGRADE_ENVS_MOUNT(fixture.repo)));
  });
});

test("another revision, an edited input or a new input is refused, or run on the image's own configs", () => {
  // A user's `status.showUntrackedFiles=no` must not hide a new input.
  const hideUntracked = {
    GIT_CONFIG_COUNT: "1",
    GIT_CONFIG_KEY_0: "status.showUntrackedFiles",
    GIT_CONFIG_VALUE_0: "no",
  };
  for (const [label, prepare, revision, gitConfig] of [
    ["another revision", () => {}, "0".repeat(40), {}],
    [
      "an edited input",
      (repo) => writeFileSync(join(repo, "l1-contracts/upgrade-envs/v1/stage.toml"), "x\n"),
      null,
      {},
    ],
    [
      "a new input",
      (repo) => writeFileSync(join(repo, "l1-contracts/upgrade-envs/v1/adi.toml"), ""),
      null,
      hideUntracked,
    ],
  ]) {
    withCheckout((fixture) => {
      prepare(fixture.repo);
      const env = { STUB_REVISION: revision ?? fixture.head, ...gitConfig };
      const refused = wrapper(fixture, ["--tag", "t", "chain", "upgrade"], env);
      assert.equal(refused.status, 1, label);
      assert.equal(refused.run, null, label);
      const release = wrapper(fixture, ["--tag", "t", "chain", "upgrade"], {
        ...env,
        PROTOCOL_OPS_REQUIRE_RELEASE: "1",
      });
      assert.equal(release.status, 0, `${label}: ${release.stderr}`);
      assert.ok(!release.run.includes(UPGRADE_ENVS_MOUNT(fixture.repo)), label);
    });
  }
});

test("PROTOCOL_OPS_REQUIRE_RELEASE refuses an image without a revision label, and local mode", () => {
  withCheckout((fixture) => {
    const release = { PROTOCOL_OPS_REQUIRE_RELEASE: "1" };
    assert.equal(wrapper(fixture, ["--tag", "t", "chain", "upgrade"], release).status, 1);
    assert.equal(wrapper(fixture, ["chain", "upgrade"], release).status, 1);
    assert.equal(wrapper(fixture, ["--tag", "", "chain", "upgrade"]).status, 1, "an empty --tag is not local mode");
    assert.equal(existsSync(join(fixture.repo, "stub/run")), false);
    assert.equal(existsSync(join(fixture.repo, "stub/local")), false);
  });
});

test("an image without a revision label is a local build, run with the checkout's upgrade-envs/", () => {
  withCheckout((fixture) => {
    writeFileSync(join(fixture.repo, "l1-contracts/upgrade-envs/v1/stage.toml"), "x\n");
    const result = wrapper(fixture, ["--tag", "local", "chain", "upgrade"]);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.run.includes(UPGRADE_ENVS_MOUNT(fixture.repo)));
  });
});

// The Etherscan key, and the run a deploy bundle records as `generated_by`.
const PASSED_THROUGH = ["ETHERSCAN_API_KEY", "GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "RUNNER_OS"];

test("EXTRA_MOUNTS are passed as given, the environment by name only", () => {
  withCheckout((fixture) => {
    const result = wrapper(fixture, ["--tag", "t", "cast", "chain-id"], {
      STUB_REVISION: fixture.head,
      EXTRA_MOUNTS: "/bundle:/bundle:ro /result:/result",
      ...Object.fromEntries(PASSED_THROUGH.map((name) => [name, `value-of-${name}`])),
    });
    assert.equal(result.status, 0, result.stderr);
    const run = result.run.join("\n");
    assert.match(run, /^-v\n\/bundle:\/bundle:ro$/m);
    assert.match(run, /^-v\n\/result:\/result$/m);
    for (const name of PASSED_THROUGH) {
      assert.match(run, new RegExp(`^-e\n${name}$`, "m"));
    }
    assert.doesNotMatch(run, /value-of-/);
    assert.ok(!result.run.includes("-w"), "cast runs in the image's working directory");
  });
});

test("forge runs from the image's l1-contracts/, for its foundry.toml", () => {
  withCheckout((fixture) => {
    const result = wrapper(fixture, ["--tag", "t", "forge", "build"], { STUB_REVISION: fixture.head });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.run.join("\n"), /^-w\n\/contracts\/l1-contracts$/m);
    assert.deepEqual(result.run.slice(-2), ["forge", "build"]);
  });
});
