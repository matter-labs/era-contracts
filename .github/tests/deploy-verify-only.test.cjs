const assert = require("node:assert/strict");
const { readFileSync, writeFileSync, mkdtempSync, rmSync } = require("node:fs");
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
    // Isolate orchestration from Etherscan/Foundry: no network or signing in these tests.
    const mock = 'forge() { printf "%s\\n" "$*" >> "$DEPLOY_BUNDLE_DIR/calls"; [[ "$*" != *bad* ]]; }\n';
    const result = spawnSync("bash", ["-c", mock + verification.run], {
      encoding: "utf8",
      env: { ...process.env, ETHERSCAN_API_KEY: key, ETHERSCAN_CHAIN: "mainnet", DEPLOY_BUNDLE_DIR: directory },
    });
    return result;
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("all successful commands pass and duplicate commands are removed", () => {
  const result = runVerification("forge verify-contract good Example\nforge verify-contract good Example\n");
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /1 succeeded, 0 failed/);
});

test("a verification failure fails the step without skipping remaining contracts", () => {
  const result = runVerification("forge verify-contract bad Example\nforge verify-contract good Example\n");
  assert.equal(result.status, 1);
  assert.match(result.stdout, /1 succeeded, 1 failed/);
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
