const assert = require("node:assert/strict");
const { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const YAML = require("yaml");

const workflow = YAML.parse(readFileSync(join(__dirname, "../workflows/deploy-ecosystem-upgrade.yaml"), "utf8"));
const steps = workflow.jobs.deploy.steps;
const verification = steps.find((step) => step.name === "Verify contracts on Etherscan");
const follower = steps.find((step) => step.name === "Start Etherscan verification alongside the broadcast");
const sourceCheck = steps.find((step) => step.name === "Check Etherscan shows this checkout's sources");
// A step that runs a script from `.github/scripts` is held to that script's text.
const scriptOf = (step) => {
  const script = /^bash (\.github\/scripts\/\S+)\n?$/.exec(step.run);
  assert.ok(script || !step.run.includes(".github/scripts/"), `${step.name}: run its script as \`bash <path>\``);
  return script ? readFileSync(join(__dirname, "../..", script[1]), "utf8") : step.run;
};
const followerScript = scriptOf(follower);
const stepIndex = (name) => {
  const index = steps.findIndex((step) => step.name === name);
  assert.notEqual(index, -1, name);
  return index;
};

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
  assert.equal(verification["continue-on-error"], true);
  assert.equal(follower.if, "${{ inputs.run_verify && !inputs.verify_only }}");
});

// Submission, retries and the parsing of bundle text are tested in protocol-ops
// (`commands/ecosystem/etherscan.rs`); these hold the workflow wiring.
test("each contract is verified as the broadcast lands it, and the shown sources are checked", () => {
  // The verifier follows the broadcast in the background, started before the deployer key is read.
  assert.equal(follower.run, "bash .github/scripts/deploy-ecosystem-upgrade/start-etherscan-follower.sh");
  assert.match(followerScript, /protocol_ops ecosystem etherscan-verify/);
  assert.match(followerScript, /--l1-rpc-url "\$L1_RPC_URL"/);
  assert.match(followerScript, /\) &\n/);
  assert.deepEqual(Object.keys(follower.env), ["ETHERSCAN_API_KEY"]);
  assert.ok(stepIndex("Select + mask the L1 RPC (L1 from the bundle)") < stepIndex(follower.name));
  assert.ok(stepIndex("Check the deployer plan against this checkout") < stepIndex(follower.name));
  assert.ok(stepIndex(follower.name) < stepIndex("Check the deployer key against the bundle"));
  // The status file appears whole: the verify step polls for it.
  assert.match(
    followerScript,
    /> "\$VERIFY_DIR\/status\.tmp"\n\s*mv "\$VERIFY_DIR\/status\.tmp" "\$VERIFY_DIR\/status"/
  );
  // The verify step stops the follower once the broadcast is over and reports its outcome, then
  // waits for every verdict: it never exits on the follower's status alone.
  assert.ok(stepIndex("Broadcast deployer bundles to L1") < stepIndex(verification.name));
  assert.match(verification.run, /broadcast-done/);
  assert.doesNotMatch(verification.run, /exit/);
  assert.match(
    verification.run,
    /protocol_ops ecosystem etherscan-verify \\\n\s+--bundle "\$DEPLOY_BUNDLE_DIR" \\\n\s+"\$\{forge_script\[@\]\}"$/m
  );
  // The source check fails the run, deployment or verification-only alike.
  assert.equal(sourceCheck.if, "${{ inputs.run_verify }}");
  assert.equal(sourceCheck["continue-on-error"], undefined);
  assert.match(sourceCheck.run, /protocol_ops ecosystem etherscan-check/);
  assert.ok(stepIndex(verification.name) < stepIndex(sourceCheck.name));
  for (const step of [follower, verification, sourceCheck]) {
    assert.doesNotMatch(scriptOf(step), /PRIVATE_KEY|PK_MAINNET|PK_SEPOLIA|upgrade-broadcast/, step.name);
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
  // It reads its L1 facts (the CTMs' ProxyAdmin, BytecodesSupplier, ...) over the RPC selected before it.
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

function runFollowerLaunch({ key, toolExit }) {
  const directory = mkdtempSync(join(tmpdir(), "follower-test-"));
  try {
    const tool = join(directory, "protocol-ops/target/release");
    mkdirSync(tool, { recursive: true });
    writeFileSync(join(tool, "protocol_ops"), `#!/bin/sh\necho "protocol_ops $*"\nexit ${toolExit}\n`, {
      mode: 0o755,
    });
    const env = {
      ...process.env,
      ETHERSCAN_API_KEY: key,
      DEPLOY_BUNDLE_DIR: "/bundle",
      L1_RPC_URL: "http://127.0.0.1:1",
      RUNNER_TEMP: directory,
      GITHUB_ENV: join(directory, "env"),
    };
    return spawnSync("bash", ["-c", followerScript], { cwd: directory, encoding: "utf8", env });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("a follower that cannot run stops the deploy before the broadcast", () => {
  const running = runFollowerLaunch({ key: "k", toolExit: 0 });
  assert.equal(running.status, 0, running.stdout + running.stderr);
  const noKey = runFollowerLaunch({ key: "", toolExit: 0 });
  assert.equal(noKey.status, 1);
  assert.match(noKey.stdout, /::error::ETHERSCAN_API_KEY is required/);
  const failed = runFollowerLaunch({ key: "k", toolExit: 1 });
  assert.equal(failed.status, 1);
  assert.match(failed.stdout, /protocol_ops ecosystem etherscan-verify[\s\S]*::error::The Etherscan verifier failed/);
});

const checkedOut = "c".repeat(40);

function runSourceCheck(earlierCommits, { shallow = true } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "source-check-test-"));
  try {
    const bin = join(directory, "bin");
    const tool = join(directory, "protocol-ops/target/release");
    mkdirSync(bin);
    mkdirSync(tool, { recursive: true });
    writeFileSync(
      join(bin, "git"),
      `#!/bin/sh
case "$*" in
  "rev-parse --is-shallow-repository") echo ${shallow} ;;
  "rev-parse HEAD") echo ${checkedOut} ;;
  *) echo "git $*" ;;
esac
`,
      { mode: 0o755 }
    );
    writeFileSync(join(tool, "protocol_ops"), '#!/bin/sh\necho "protocol_ops $*"\n', { mode: 0o755 });
    return spawnSync("bash", ["-c", sourceCheck.run], {
      cwd: directory,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        DEPLOY_BUNDLE_DIR: "/bundle",
        UPGRADE_KIND: "prepare-all",
        ETHERSCAN_EARLIER_COMMITS: earlierCommits,
      },
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("the source check accepts the earlier cuts it is given, from this checkout's history", () => {
  assert.equal(sourceCheck.env.ETHERSCAN_EARLIER_COMMITS, "${{ inputs.etherscan_earlier_commits }}");
  const none = runSourceCheck("");
  assert.equal(none.status, 0, none.stderr);
  assert.equal(none.stdout, "protocol_ops ecosystem etherscan-check --bundle /bundle\n");
  const [first, second] = ["a".repeat(40), "b".repeat(40)];
  const two = runSourceCheck(` ${first}  ${second} `);
  assert.equal(two.status, 0, two.stderr);
  assert.equal(
    two.stdout,
    `git fetch --no-tags --unshallow origin ${checkedOut}\n` +
      `protocol_ops ecosystem etherscan-check --bundle /bundle --also-commit ${first} --also-commit ${second}\n`
  );
  const fullClone = runSourceCheck(first, { shallow: false });
  assert.equal(fullClone.status, 0, fullClone.stderr);
  assert.equal(fullClone.stdout, `protocol_ops ecosystem etherscan-check --bundle /bundle --also-commit ${first}\n`);
  for (const bad of ["--upload-pack=touch", "HEAD", "a".repeat(39), "A".repeat(40)]) {
    const result = runSourceCheck(`${first} ${bad}`);
    assert.equal(result.status, 1, bad);
    assert.doesNotMatch(result.stdout, /protocol_ops/, bad);
    assert.match(result.stdout, /::error::etherscan_earlier_commits/, bad);
  }
});

test("the deployer key never reaches $GITHUB_ENV, and only the key check and broadcast steps read it", () => {
  for (const step of steps.filter((step) => step.run)) {
    assert.doesNotMatch(scriptOf(step), /DEPLOYER_PK/, step.name);
    assert.doesNotMatch(scriptOf(step), /echo\s+"[A-Z_]+=\$pk"/, step.name);
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
