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
const deployPull = YAML.parse(
  readFileSync(join(workflows, "deploy-ecosystem-upgrade.yaml"), "utf8")
).jobs.deploy.steps.find((step) => step.name === "Pull the bundle's protocol-ops image").run;
const handoffBundle = YAML.parse(
  readFileSync(join(workflows, "generate-ecosystem-upgrade-calldata.yaml"), "utf8")
).jobs["verify-bundle-handoff"].steps.find((step) => step.name === "Require a bundle to hand off").run;

const DIGEST = `ghcr.io/matter-labs/protocol-ops@sha256:${"a".repeat(64)}`;
const COMMIT = "b".repeat(40);

function run(script, bundleDir, metadata, label = COMMIT) {
  const temp = mkdtempSync(join(tmpdir(), "bundle-image-checks-"));
  try {
    mkdirSync(join(temp, "bin"));
    writeFileSync(
      join(temp, "bin/docker"),
      `[[ "$1" == pull ]] && exit 0\n[[ "$*" == *revision* ]] && printf '%s\\n' "$STUB_LABEL"\n`,
      { mode: 0o755 }
    );
    mkdirSync(join(temp, bundleDir), { recursive: true });
    writeFileSync(join(temp, bundleDir, "bundle-metadata.json"), JSON.stringify(metadata));
    writeFileSync(join(temp, "out"), "");
    const result = spawnSync("bash", ["-e", "-c", script], {
      encoding: "utf8",
      env: {
        PATH: `${join(temp, "bin")}:${process.env.PATH}`,
        RUNNER_TEMP: temp,
        GITHUB_ENV: join(temp, "out"),
        GITHUB_OUTPUT: join(temp, "out"),
        STUB_LABEL: label,
      },
    });
    return { ...result, out: readFileSync(join(temp, "out"), "utf8").replaceAll(temp, "$RUNNER_TEMP") };
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

const deploy = (metadata, label) => run(deployPull, "deploy/inputs", metadata, label);
const handoff = (metadata) => run(handoffBundle, "deploy-bundle", metadata);

test("deploy pulls the bundle's image and checks it was built from the bundle's commit", () => {
  const result = deploy({ protocol_ops_image: { digest: DIGEST }, contracts_commit: COMMIT });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.out, new RegExp(`^BUNDLE_IMAGE=sha256:${"a".repeat(64)}$`, "m"));
  assert.match(result.out, new RegExp(`^BUNDLE_COMMIT=${COMMIT}$`, "m"));
  assert.match(result.out, /^EXTRA_MOUNTS=\$RUNNER_TEMP\/deploy\/inputs:\$RUNNER_TEMP\/deploy\/inputs:ro /m);
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
    assert.equal(result.out, "", label);
  }
});

test("the handoff takes the image digest and commit, nothing else", () => {
  const result = handoff({ protocol_ops_image: { digest: DIGEST }, contracts_commit: COMMIT });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.out, `image=sha256:${"a".repeat(64)}\ncommit=${COMMIT}\n`);
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
    assert.equal(refused.out, "", label);
  }
});
