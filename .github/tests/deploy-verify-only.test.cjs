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
    "Check the deployer plan in the bundle's image",
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
  assert.match(followerScript, /protocol-ops\.sh --tag "\$BUNDLE_IMAGE" ecosystem etherscan-verify/);
  assert.match(followerScript, /--l1-rpc-url "\$L1_RPC_URL"/);
  assert.match(followerScript, /\) &\n/);
  assert.deepEqual(Object.keys(follower.env), ["ETHERSCAN_API_KEY"]);
  assert.ok(stepIndex("Select + mask the L1 RPC (L1 from the bundle)") < stepIndex(follower.name));
  assert.ok(stepIndex("Check the deployer plan in the bundle's image") < stepIndex(follower.name));
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
    /protocol-ops\.sh --tag "\$BUNDLE_IMAGE" ecosystem etherscan-verify \\\n\s+--bundle "\$DEPLOY_BUNDLE_DIR" \\\n\s+"\$\{forge_script\[@\]\}"$/m
  );
  // The source check fails the run, deployment or verification-only alike.
  assert.equal(sourceCheck.if, "${{ inputs.run_verify }}");
  assert.equal(sourceCheck["continue-on-error"], undefined);
  assert.match(sourceCheck.run, /protocol-ops\.sh --tag "\$BUNDLE_IMAGE" ecosystem etherscan-check/);
  assert.ok(stepIndex(verification.name) < stepIndex(sourceCheck.name));
  for (const step of [follower, verification, sourceCheck]) {
    assert.doesNotMatch(scriptOf(step), /PRIVATE_KEY|PK_MAINNET|PK_SEPOLIA|upgrade-broadcast/, step.name);
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

// `then`, if given, runs in the launch's directory once the verifier has exited.
function runFollowerLaunch({ key, toolExit, toolDelay = 0, then }) {
  const directory = mkdtempSync(join(tmpdir(), "follower-test-"));
  try {
    writeFileSync(
      join(directory, "protocol-ops.sh"),
      `echo "protocol-ops.sh $*"\nsleep ${toolDelay}\nexit ${toolExit}\n`
    );
    const env = {
      ...process.env,
      ETHERSCAN_API_KEY: key,
      BUNDLE_IMAGE: "sha256:image",
      EXTRA_MOUNTS: "/bundle:/bundle:ro",
      DEPLOY_BUNDLE_DIR: "/bundle",
      L1_RPC_URL: "http://127.0.0.1:1",
      RUNNER_TEMP: directory,
      GITHUB_ENV: join(directory, "env"),
    };
    // Returns once the backgrounded verifier closes its inherited stdout, i.e. has exited.
    const launch = spawnSync("bash", ["-c", followerScript], { cwd: directory, encoding: "utf8", env });
    return then ? then(launch, directory) : launch;
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

// The broadcast step after a launch in `directory`, with a stand-in protocol-ops.sh that halts as
// `upgrade-broadcast --halt-when` does.
function runBroadcast(directory) {
  const broadcast = steps[stepIndex("Broadcast deployer bundles to L1")];
  writeFileSync(
    join(directory, "protocol-ops.sh"),
    `echo "protocol-ops.sh $*"
while [ $# -gt 0 ]; do
  if [ "$1" = --halt-when ] && [ -f "$2" ]; then echo "$2 exists: stopped before Safe tx #0"; exit 1; fi
  shift
done
`
  );
  const exported = Object.fromEntries(
    readFileSync(join(directory, "env"), "utf8")
      .trim()
      .split("\n")
      .map((line) => line.split(/=(.*)/s).slice(0, 2))
  );
  return spawnSync("bash", ["-c", broadcast.run], {
    cwd: directory,
    encoding: "utf8",
    env: {
      ...process.env,
      ...exported,
      BUNDLE_IMAGE: "sha256:image",
      L1_NETWORK: "sepolia",
      PK_SEPOLIA: "0x01",
      DEPLOYER_ADDR: "0x02",
      DEPLOY_BUNDLE_DIR: "/bundle",
      L1_RPC_URL: "http://127.0.0.1:1",
      DEPLOY_OUTDIR: directory,
      TXLOG: join(directory, "transactions.txt"),
      MAX_GAS_PRICE_GWEI: "500",
    },
  });
}

test("a follower that cannot run stops the deploy before the broadcast", () => {
  const running = runFollowerLaunch({
    key: "k",
    toolExit: 0,
    then: (launch, directory) => ({ ...launch, exported: readFileSync(join(directory, "env"), "utf8") }),
  });
  assert.equal(running.status, 0, running.stdout + running.stderr);
  // Its directory is mounted at the same path in the image, where the broadcast's --halt-when reads it.
  assert.match(running.exported, /^EXTRA_MOUNTS=\/bundle:\/bundle:ro (\S+\/etherscan-verify):\1$/m);
  const noKey = runFollowerLaunch({ key: "", toolExit: 0 });
  assert.equal(noKey.status, 1);
  assert.match(noKey.stdout, /::error::ETHERSCAN_API_KEY is required/);
  const failed = runFollowerLaunch({ key: "k", toolExit: 1 });
  assert.equal(failed.status, 1);
  assert.match(
    failed.stdout,
    /protocol-ops\.sh --tag sha256:image ecosystem etherscan-verify[\s\S]*::error::The Etherscan verifier failed/
  );
});

test("a verifier that exits during the broadcast stops it before its next transaction", () => {
  // Past the launch's own check: the launch passes, and only the broadcast can stop.
  const late = runFollowerLaunch({
    key: "k",
    toolExit: 1,
    toolDelay: 6,
    then: (launch, directory) => {
      assert.equal(launch.status, 0, launch.stdout + launch.stderr);
      return runBroadcast(directory);
    },
  });
  assert.equal(late.status, 1);
  assert.match(late.stdout, /--halt-when \S+\/etherscan-verify\/failed\n\S+\/etherscan-verify\/failed exists/);
  assert.match(
    late.stdout,
    /protocol-ops\.sh --tag sha256:image ecosystem etherscan-verify[\s\S]*::error::The Etherscan verifier exited/
  );
  // A verifier that is done (it submitted every contract) does not stop the broadcast.
  const done = runFollowerLaunch({ key: "k", toolExit: 0, then: (launch, directory) => runBroadcast(directory) });
  assert.equal(done.status, 0, done.stdout + done.stderr);
  assert.match(done.stdout, /--halt-when \S+\/etherscan-verify\/failed\n/);
});

const checkedOut = "c".repeat(40);

function runSourceCheck(earlierCommits, { shallow = true } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "source-check-test-"));
  try {
    const bin = join(directory, "bin");
    mkdirSync(bin);
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
    writeFileSync(join(directory, "protocol-ops.sh"), 'echo "mounts: $EXTRA_MOUNTS"\necho "protocol-ops.sh $*"\n');
    return spawnSync("bash", ["-c", sourceCheck.run], {
      cwd: directory,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        DEPLOY_BUNDLE_DIR: "/bundle",
        BUNDLE_IMAGE: "sha256:image",
        EXTRA_MOUNTS: "/bundle:/bundle:ro",
        GITHUB_WORKSPACE: "/work",
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
  assert.equal(
    none.stdout,
    "mounts: /bundle:/bundle:ro\nprotocol-ops.sh --tag sha256:image ecosystem etherscan-check --bundle /bundle\n"
  );
  const [first, second] = ["a".repeat(40), "b".repeat(40)];
  const two = runSourceCheck(` ${first}  ${second} `);
  assert.equal(two.status, 0, two.stderr);
  assert.equal(
    two.stdout,
    `git fetch --no-tags --unshallow origin ${checkedOut}\n` +
      // The image has no repository: it reads the earlier cuts from this checkout's.
      `mounts: /bundle:/bundle:ro /work/.git:/contracts/.git:ro\n` +
      `protocol-ops.sh --tag sha256:image ecosystem etherscan-check --bundle /bundle ` +
      `--also-commit ${first} --also-commit ${second}\n`
  );
  const fullClone = runSourceCheck(first, { shallow: false });
  assert.equal(fullClone.status, 0, fullClone.stderr);
  assert.equal(
    fullClone.stdout,
    `mounts: /bundle:/bundle:ro /work/.git:/contracts/.git:ro\n` +
      `protocol-ops.sh --tag sha256:image ecosystem etherscan-check --bundle /bundle --also-commit ${first}\n`
  );
  for (const bad of ["--upload-pack=touch", "HEAD", "a".repeat(39), "A".repeat(40)]) {
    const result = runSourceCheck(`${first} ${bad}`);
    assert.equal(result.status, 1, bad);
    assert.doesNotMatch(result.stdout, /protocol-ops\.sh/, bad);
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
