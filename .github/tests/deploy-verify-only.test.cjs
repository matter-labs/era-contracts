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
    "Check the deployer plan against this checkout",
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
    mkdirSync(join(directory, "l1-contracts"));
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
    const pwned = watchForInjection
      ? existsSync(join(directory, "pwned")) || existsSync(join(directory, "l1-contracts", "pwned"))
      : undefined;
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

test("DA contracts verify from l1-contracts without changing recorded constructor arguments", () => {
  const result = runVerification(
    `forge verify-contract ${A1} EIP7702Checker\n` +
      `forge verify-contract ${A2} RollupL1DAValidator --constructor-args 0x1234\n` +
      `forge verify-contract ${A3} CommitterFacet --constructor-args 0x5678\n`
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.calls, [
    `l1-contracts|verify-contract ${A1} EIP7702Checker --chain mainnet --watch --retries 8 --delay 20`,
    `l1-contracts|verify-contract ${A2} RollupL1DAValidator --constructor-args 0x1234 --chain mainnet --watch --retries 8 --delay 20`,
    `l1-contracts|verify-contract ${A3} CommitterFacet --constructor-args 0x5678 --chain mainnet --watch --retries 8 --delay 20`,
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
      `l1-contracts|verify-contract ${A2} good --chain mainnet --watch --retries 8 --delay 20`,
    ]);
    assert.equal(result.pwned, false, line);
  }
});

test("the deployer plan is checked against the checkout before any step reads the deployer key", () => {
  // The plan check holds the build to AllContractsHashes.json, which a recursive checkout produces.
  assert.equal(steps[stepIndex("Checkout the repository")].with.submodules, "recursive");
  const check = steps[stepIndex("Check the deployer plan against this checkout")];
  assert.match(
    check.run,
    /protocol_ops ecosystem check-deployer-plan \\\s+--bundle "\$DEPLOY_BUNDLE_DIR" \\\s+--l1-rpc-url "\$L1_RPC_URL"/
  );
  assert.equal(check.env, undefined);
  // It reads the CTMs' ProxyAdmin and BytecodesSupplier over the RPC selected before it.
  assert.ok(
    stepIndex("Select + mask the L1 RPC (L1 from the bundle)") <
      stepIndex("Check the deployer plan against this checkout")
  );
  const build = steps[stepIndex("Build contracts (for the deployer plan check and Etherscan verify)")];
  assert.equal(build.if, "${{ inputs.run_verify || !inputs.verify_only }}");
  assert.ok(
    stepIndex("Build contracts (for the deployer plan check and Etherscan verify)") <
      stepIndex("Check the deployer plan against this checkout")
  );
  assert.ok(
    stepIndex("Check bundle provenance against the proven run") <
      stepIndex("Check the deployer plan against this checkout")
  );
  for (const reader of ["Check the deployer key against the bundle", "Broadcast deployer bundles to L1"]) {
    assert.ok(stepIndex("Check the deployer plan against this checkout") < stepIndex(reader), reader);
  }
});

function runProvenance(overrides) {
  const directory = mkdtempSync(join(tmpdir(), "provenance-test-"));
  try {
    const metadata = {
      contracts_commit: "a".repeat(40),
      generated_by: { workflow_run: "https://github.com/o/r/actions/runs/1" },
      env: "stage",
      contracts_worktree_dirty: false,
    };
    writeFileSync(join(directory, "bundle-metadata.json"), JSON.stringify(metadata));
    const provenance = steps[stepIndex("Check bundle provenance against the proven run")];
    return spawnSync("bash", ["-c", provenance.run], {
      encoding: "utf8",
      env: {
        ...process.env,
        DEPLOY_BUNDLE_DIR: directory,
        GENERATE_RUN_URL: metadata.generated_by.workflow_run,
        GENERATE_HEAD_SHA: metadata.contracts_commit,
        ENVIRONMENT: "stage",
        GITHUB_SHA: metadata.contracts_commit,
        ...overrides,
      },
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("a deploy run on another commit than the generation is refused", () => {
  assert.equal(runProvenance({}).status, 0);
  const result = runProvenance({ GITHUB_SHA: "b".repeat(40) });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /::error::bundle was generated from a{40} but this run checked out b{40}/);
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
