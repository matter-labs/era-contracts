const assert = require("node:assert/strict");
const { readFileSync, writeFileSync, mkdtempSync, mkdirSync, existsSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const YAML = require("yaml");

const workflow = YAML.parse(readFileSync(join(__dirname, "../workflows/deploy-ecosystem-upgrade.yaml"), "utf8"));
const steps = workflow.jobs.deploy.steps;
const verification = steps.find((step) => step.name === "Verify contracts on Etherscan");
const stepIndex = (name) => {
  const index = steps.findIndex((step) => step.name === name);
  assert.notEqual(index, -1, name);
  return index;
};
// Etherscan verification lines carry real-looking addresses: the step refuses any other shape.
const A1 = "0x0000000000000000000000000000000000000001";
const A2 = "0x0000000000000000000000000000000000000002";
const A3 = "0x0000000000000000000000000000000000000003";

test("verification-only mode cannot load signing keys, broadcast, or overwrite receipts", () => {
  assert.equal(workflow.on.workflow_dispatch.inputs.verify_only.default, false);
  for (const name of [
    "Select + mask the L1 RPC (L1 from the bundle)",
    "Check the deployer key against the bundle",
    "Broadcast deployer bundles to L1",
    "Initialize or restore the deployment receipt journal",
    "Check the deployer plan in the bundle's image",
  ]) {
    assert.equal(steps.find((step) => step.name === name).if, "${{ !inputs.verify_only }}");
  }
  assert.equal(
    steps.find((step) => step.name === "Upload transactions.txt + executed log").if,
    "${{ always() && !inputs.verify_only }}"
  );
  assert.equal(verification["continue-on-error"], "${{ !inputs.verify_only }}");
  const network = steps.find((step) => step.name === "Select Etherscan network for verification only");
  assert.equal(network.if, "${{ inputs.verify_only }}");
  assert.doesNotMatch(network.run, /DEPLOYER_PK|PRIVATE_KEY|upgrade-broadcast/);
});

function runVerification(log, key = "test-placeholder", watchForInjection = false) {
  const directory = mkdtempSync(join(tmpdir(), "verify-only-test-"));
  try {
    if (log !== null) writeFileSync(join(directory, "extra-verification-logs.txt"), log);
    // Isolate orchestration from Etherscan, Foundry and docker: no network or signing in these tests.
    writeFileSync(
      join(directory, "protocol-ops.sh"),
      `printf '%s\\n' "$*" >> "$DEPLOY_BUNDLE_DIR/calls"
      if [[ "$*" == *flaky* ]] && [ ! -f "$DEPLOY_BUNDLE_DIR/retried" ]; then
        touch "$DEPLOY_BUNDLE_DIR/retried"
        exit 1
      fi
      [[ "$*" != *bad* ]]
      `
    );
    const result = spawnSync("bash", ["-c", "sleep() { :; }\n" + verification.run], {
      encoding: "utf8",
      cwd: directory,
      env: {
        ...process.env,
        ETHERSCAN_API_KEY: key,
        ETHERSCAN_CHAIN: "mainnet",
        DEPLOY_BUNDLE_DIR: directory,
        GITHUB_WORKSPACE: directory,
        BUNDLE_IMAGE: "sha256:image",
      },
    });
    const calls = join(directory, "calls");
    const pwned = watchForInjection ? existsSync(join(directory, "pwned")) : undefined;
    return { ...result, pwned, calls: existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n") : [] };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("all successful commands pass and duplicate commands are removed", () => {
  const result = runVerification(`forge verify-contract ${A1} good\nforge verify-contract ${A1} good\n`);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /1 succeeded, 0 failed/);
  assert.equal(result.calls.length, 1);
});

test("a verification failure fails the step without skipping remaining contracts", () => {
  const result = runVerification(`forge verify-contract ${A1} bad\nforge verify-contract ${A2} good\n`);
  assert.equal(result.status, 1);
  assert.match(result.stdout, /1 succeeded, 1 failed/);
  assert.equal(result.calls.filter((call) => call.includes("bad")).length, 3);
  assert.equal(result.calls.filter((call) => call.includes("good")).length, 1);
});

test("DA contracts verify without changing recorded constructor arguments", () => {
  const result = runVerification(
    `forge verify-contract ${A1} EIP7702Checker\n` +
      `forge verify-contract ${A2} RollupL1DAValidator --constructor-args 0x1234\n` +
      `forge verify-contract ${A3} CommitterFacet --constructor-args 0x5678\n`
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.calls, [
    `--tag sha256:image forge verify-contract ${A1} EIP7702Checker --chain mainnet --watch --retries 8 --delay 20`,
    `--tag sha256:image forge verify-contract ${A2} RollupL1DAValidator --constructor-args 0x1234 --chain mainnet --watch --retries 8 --delay 20`,
    `--tag sha256:image forge verify-contract ${A3} CommitterFacet --constructor-args 0x5678 --chain mainnet --watch --retries 8 --delay 20`,
  ]);
});

test("a transient initial request failure is retried and counted once", () => {
  const result = runVerification(`forge verify-contract ${A1} flaky\n`);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.length, 2);
  assert.equal(result.calls[0], result.calls[1]);
  assert.match(result.stdout, /1 succeeded, 0 failed/);
});

test("missing key, missing log, and empty verification list fail closed", () => {
  for (const [log, key] of [
    [`forge verify-contract ${A1} good\n`, ""],
    [null, "test-placeholder"],
    ["", "test-placeholder"],
  ]) {
    assert.equal(runVerification(log, key).status, 1);
  }
});

test("bundle text is parsed, never evaluated: a line of any other shape is not run and fails", () => {
  for (const line of [
    `forge verify-contract ${A1} good; touch "$DEPLOY_BUNDLE_DIR/pwned"`,
    `forge verify-contract ${A1} $(touch "$DEPLOY_BUNDLE_DIR/pwned")`,
    `forge verify-contract ${A1} good --constructor-args 0x12\`touch pwned\``,
    `forge verify-contract good Example`,
    `forge verify-contract ${A1} good --constructor-args 0x12 --flatten`,
  ]) {
    const result = runVerification(`forge verify-contract ${A2} good\n${line}\n`, "test-placeholder", true);
    assert.equal(result.status, 1, line);
    assert.match(result.stdout, /1 succeeded, 1 failed/, line);
    assert.deepEqual(result.calls, [
      `--tag sha256:image forge verify-contract ${A2} good --chain mainnet --watch --retries 8 --delay 20`,
    ]);
    assert.equal(result.pwned, false, line);
  }
});

test("the deployer plan is checked in the bundle's image before any step reads the deployer key", () => {
  const check = steps[stepIndex("Check the deployer plan in the bundle's image")];
  assert.match(
    check.run,
    /protocol-ops\.sh --tag "\$BUNDLE_IMAGE" ecosystem check-deployer-plan \\\s+--bundle "\$DEPLOY_BUNDLE_DIR" \\\s+--l1-rpc-url "\$L1_RPC_URL"/
  );
  assert.equal(check.env, undefined);
  // It reads its L1 facts (the CTMs' ProxyAdmin, BytecodesSupplier, ...) over the RPC selected before it.
  assert.ok(
    stepIndex("Select + mask the L1 RPC (L1 from the bundle)") <
      stepIndex("Check the deployer plan in the bundle's image")
  );
  assert.ok(
    stepIndex("Check bundle provenance against the proven run") <
      stepIndex("Check the deployer plan in the bundle's image")
  );
  for (const reader of ["Check the deployer key against the bundle", "Broadcast deployer bundles to L1"]) {
    assert.ok(stepIndex("Check the deployer plan in the bundle's image") < stepIndex(reader), reader);
  }
});

function pullImage(revision) {
  const directory = mkdtempSync(join(tmpdir(), "image-test-"));
  try {
    mkdirSync(join(directory, "deploy", "inputs"), { recursive: true });
    const metadata = {
      contracts_commit: "a".repeat(40),
      protocol_ops_image: { digest: `ghcr.io/matter-labs/protocol-ops@sha256:${"0".repeat(64)}` },
    };
    writeFileSync(join(directory, "deploy", "inputs", "bundle-metadata.json"), JSON.stringify(metadata));
    const pull = steps[stepIndex("Pull the bundle's protocol-ops image")];
    return spawnSync("bash", ["-c", `docker() { [ "$1" = pull ] || echo ${revision}; }\n` + pull.run], {
      encoding: "utf8",
      env: { ...process.env, RUNNER_TEMP: directory, GITHUB_ENV: join(directory, "github-env") },
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("a deploy runs the image and checkout of the bundle's commit, and no other", () => {
  assert.equal(pullImage("a".repeat(40)).status, 0);
  const result = pullImage("b".repeat(40));
  assert.equal(result.status, 1);
  assert.match(result.stdout, /::error::.* was built from 'b{40}', the bundle from 'a{40}'/);
  assert.equal(steps[stepIndex("Checkout the bundle's commit")].with.ref, "${{ env.BUNDLE_COMMIT }}");
});

test("the deployer key never reaches $GITHUB_ENV, and only the key check and broadcast steps read it", () => {
  for (const step of steps.filter((step) => step.run)) {
    assert.doesNotMatch(step.run, /DEPLOYER_PK/, step.name);
    assert.doesNotMatch(step.run, /echo\s+"[A-Z_]+=\$pk"/, step.name);
  }
  const readers = steps
    .filter((step) => Object.values(step.env ?? {}).some((value) => String(value).includes("DEPLOYER_PRIVATE_KEY")))
    .map((step) => step.name);
  assert.deepEqual(readers, ["Check the deployer key against the bundle", "Broadcast deployer bundles to L1"]);
});

test("run scripts take dispatch inputs through env, never by expression expansion", () => {
  for (const step of steps.filter((step) => step.run)) {
    assert.doesNotMatch(step.run, /\$\{\{\s*inputs\./, step.name);
  }
});
