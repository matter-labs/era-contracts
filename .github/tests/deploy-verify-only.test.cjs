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

test("verification-only mode cannot load signing keys, broadcast, or overwrite receipts", () => {
  assert.equal(workflow.on.workflow_dispatch.inputs.verify_only.default, false);
  for (const name of [
    "Select + mask RPC and deployer key (L1 from the bundle)",
    "Broadcast deployer bundles to L1",
    "Initialize or restore the deployment receipt journal",
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

function runVerification(log, key = "test-placeholder") {
  const directory = mkdtempSync(join(tmpdir(), "verify-only-test-"));
  try {
    if (log !== null) writeFileSync(join(directory, "extra-verification-logs.txt"), log);
    mkdirSync(join(directory, "l1-contracts"));
    mkdirSync(join(directory, "da-contracts"));
    // Isolate orchestration from Etherscan/Foundry: no network or signing in these tests.
    const mock = `forge() {
      printf '%s|%s\\n' "$(basename "$PWD")" "$*" >> "$DEPLOY_BUNDLE_DIR/calls"
      if [[ "$*" == *flaky* ]] && [ ! -f "$DEPLOY_BUNDLE_DIR/retried" ]; then
        touch "$DEPLOY_BUNDLE_DIR/retried"
        return 1
      fi
      [[ "$*" != *bad* ]]
    }
    sleep() { :; }
    `;
    const result = spawnSync("bash", ["-c", mock + verification.run], {
      encoding: "utf8",
      cwd: join(directory, "l1-contracts"),
      env: { ...process.env, ETHERSCAN_API_KEY: key, ETHERSCAN_CHAIN: "mainnet", DEPLOY_BUNDLE_DIR: directory },
    });
    const calls = join(directory, "calls");
    return { ...result, calls: existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n") : [] };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("all successful commands pass and duplicate commands are removed", () => {
  const result = runVerification("forge verify-contract good Example\nforge verify-contract good Example\n");
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /1 succeeded, 0 failed/);
  assert.equal(result.calls.length, 1);
});

test("a verification failure fails the step without skipping remaining contracts", () => {
  const result = runVerification("forge verify-contract bad Example\nforge verify-contract good Example\n");
  assert.equal(result.status, 1);
  assert.match(result.stdout, /1 succeeded, 1 failed/);
  assert.equal(result.calls.filter((call) => call.includes("bad")).length, 3);
  assert.equal(result.calls.filter((call) => call.includes("good")).length, 1);
});

test("DA contracts use their own workspace without changing recorded constructor arguments", () => {
  const result = runVerification(
    "forge verify-contract first EIP7702Checker\n" +
      "forge verify-contract second RollupL1DAValidator --constructor-args 0x1234\n" +
      "forge verify-contract third CommitterFacet --constructor-args 0x5678\n"
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.calls, [
    "da-contracts|verify-contract first EIP7702Checker --chain mainnet --watch --retries 8 --delay 20",
    "da-contracts|verify-contract second RollupL1DAValidator --constructor-args 0x1234 --chain mainnet --watch --retries 8 --delay 20",
    "l1-contracts|verify-contract third CommitterFacet --constructor-args 0x5678 --chain mainnet --watch --retries 8 --delay 20",
  ]);
});

test("a transient initial request failure is retried and counted once", () => {
  const result = runVerification("forge verify-contract flaky CommitterFacet\n");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.length, 2);
  assert.equal(result.calls[0], result.calls[1]);
  assert.match(result.stdout, /1 succeeded, 0 failed/);
});

test("missing key, missing log, and empty verification list fail closed", () => {
  for (const [log, key] of [
    ["forge verify-contract good Example\n", ""],
    [null, "test-placeholder"],
    ["", "test-placeholder"],
  ]) {
    assert.equal(runVerification(log, key).status, 1);
  }
});
