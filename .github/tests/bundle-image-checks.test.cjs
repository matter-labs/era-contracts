const assert = require("node:assert/strict");
const { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const YAML = require("yaml");

// The steps that take the image and the commit from a downloaded deploy bundle: deploy pulls that
// image before any key is loaded, the handoff job replays in it. A pre-push image has no registry
// digest, so build-docker's release flow can't reach these checks; they run here against a stub
// `docker` and crafted bundle metadata.
const workflows = join(__dirname, "../workflows");
const deployJob = YAML.parse(readFileSync(join(workflows, "deploy-ecosystem-upgrade.yaml"), "utf8")).jobs.deploy;
const handoffJob = YAML.parse(readFileSync(join(workflows, "generate-ecosystem-upgrade-calldata.yaml"), "utf8")).jobs[
  "verify-bundle-handoff"
];
const deployPull = deployJob.steps.find((step) => step.name === "Pull the bundle's protocol-ops image");
const handoffBundle = handoffJob.steps.find((step) => step.name === "Require a bundle to hand off");

const DIGEST = `ghcr.io/matter-labs/protocol-ops@sha256:${"a".repeat(64)}`;
const COMMIT = "b".repeat(40);

// Logs each call's subcommand and image; answers the revision-label inspect with STUB_LABEL.
const STUB_DOCKER = `printf '%s %s\\n' "$1" "\${!#}" >> "$STUB_CALLS"
[[ "$1" == pull ]] && exit 0
[[ "$*" == *revision* ]] && printf '%s\\n' "$STUB_LABEL"
`;

function run(script, bundleDir, metadata, label = COMMIT) {
  const temp = mkdtempSync(join(tmpdir(), "bundle-image-checks-"));
  try {
    mkdirSync(join(temp, "bin"));
    writeFileSync(join(temp, "bin/docker"), STUB_DOCKER, { mode: 0o755 });
    mkdirSync(join(temp, bundleDir), { recursive: true });
    writeFileSync(join(temp, bundleDir, "bundle-metadata.json"), JSON.stringify(metadata));
    const files = { env: join(temp, "env"), output: join(temp, "output"), calls: join(temp, "calls") };
    Object.values(files).forEach((file) => writeFileSync(file, ""));
    const result = spawnSync("bash", ["-e", "-c", script], {
      encoding: "utf8",
      env: {
        PATH: `${join(temp, "bin")}:${process.env.PATH}`,
        RUNNER_TEMP: temp,
        GITHUB_ENV: files.env,
        GITHUB_OUTPUT: files.output,
        STUB_CALLS: files.calls,
        STUB_LABEL: label,
      },
    });
    const read = (file) => readFileSync(file, "utf8").replaceAll(temp, "$RUNNER_TEMP");
    return { ...result, env: read(files.env), output: read(files.output), calls: read(files.calls) };
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

const deploy = (metadata, label) => run(deployPull.run, "deploy/inputs", metadata, label);
const handoff = (metadata) => run(handoffBundle.run, "deploy-bundle", metadata);

test("deploy pulls the bundle's image and checks it was built from the bundle's commit", () => {
  const result = deploy({ protocol_ops_image: { digest: DIGEST }, contracts_commit: COMMIT });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls, `pull ${DIGEST}\nimage ${DIGEST}\n`);
  assert.match(result.env, new RegExp(`^BUNDLE_IMAGE=sha256:${"a".repeat(64)}$`, "m"));
  assert.match(result.env, new RegExp(`^BUNDLE_COMMIT=${COMMIT}$`, "m"));
  assert.match(result.env, /^EXTRA_MOUNTS=\$RUNNER_TEMP\/deploy\/inputs:\$RUNNER_TEMP\/deploy\/inputs:ro /m);
  assert.equal(result.output, "");
});

test("deploy refuses a bundle without a released image, or an image built from another commit", () => {
  for (const [label, metadata, imageLabel] of [
    ["no image", { contracts_commit: COMMIT }, COMMIT],
    [
      "another registry",
      { protocol_ops_image: { digest: DIGEST.replace("ghcr.io", "evil.io") }, contracts_commit: COMMIT },
      COMMIT,
    ],
    ["another commit", { protocol_ops_image: { digest: DIGEST }, contracts_commit: COMMIT }, "c".repeat(40)],
    [
      "an injected line",
      { protocol_ops_image: { digest: DIGEST }, contracts_commit: `${COMMIT}\nBASH_ENV=x` },
      `${COMMIT}\nBASH_ENV=x`,
    ],
  ]) {
    const result = deploy(metadata, imageLabel);
    assert.equal(result.status, 1, label);
    assert.equal(result.env, "", label);
  }
});

test("the handoff takes the image digest and commit, nothing else", () => {
  const result = handoff({ protocol_ops_image: { digest: DIGEST }, contracts_commit: COMMIT });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, `image=sha256:${"a".repeat(64)}\ncommit=${COMMIT}\n`);
  assert.equal(result.env, "");
  for (const [label, metadata] of [
    ["no image", { contracts_commit: COMMIT }],
    [
      "another registry",
      { protocol_ops_image: { digest: DIGEST.replace("ghcr.io", "evil.io") }, contracts_commit: COMMIT },
    ],
    ["an injected digest", { protocol_ops_image: { digest: `${DIGEST}\ncommit=x` }, contracts_commit: COMMIT }],
    ["an injected commit", { protocol_ops_image: { digest: DIGEST }, contracts_commit: `${COMMIT}\nimage=x` }],
  ]) {
    const refused = handoff(metadata);
    assert.notEqual(refused.status, 0, label);
    assert.equal(refused.output, "", label);
  }
});

// An unset step output is an empty string: the checkout would take the triggering ref.
test("deploy and the handoff run the bundle's image from a checkout of the bundle's commit", () => {
  assert.equal(handoffBundle.id, "bundle");
  for (const [job, ref, image] of [
    [deployJob, "${{ env.BUNDLE_COMMIT }}", undefined],
    [handoffJob, "${{ steps.bundle.outputs.commit }}", "${{ steps.bundle.outputs.image }}"],
  ]) {
    const checkouts = job.steps.filter((step) => step.uses?.startsWith("actions/checkout@"));
    assert.deepEqual(
      checkouts.map((step) => step.with.ref),
      [ref]
    );
    const runs = job.steps.filter((step) => step.run?.includes("protocol-ops.sh"));
    assert.ok(runs.length > 0);
    for (const step of runs) {
      for (const [, args] of step.run.matchAll(/protocol-ops\.sh"? (.*)/g)) {
        assert.match(args, /^--tag "\$BUNDLE_IMAGE" /, step.name);
      }
      assert.equal(step.env?.BUNDLE_IMAGE, image, step.name);
    }
  }
});
