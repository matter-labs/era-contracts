#!/usr/bin/env node

/**
 * Fixture tests for prune-stale-artifacts.js.
 *
 * This script decides whether restored artifacts are trusted, and every bug found in it so far was
 * invisible to CI: they need a deleted or modified source, a duplicated basename, or a malformed
 * manifest to show up, and none of those occur in an ordinary run. So they are pinned here.
 *
 * Each case builds a throwaway git repo, because identity comes from git blob hashes.
 *
 * Run with: node prune-stale-artifacts.test.js
 */

const assert = require("assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const SCRIPT = path.join(__dirname, "prune-stale-artifacts.js");
const MANIFEST_WRITER = path.join(__dirname, "write-source-manifest.js");

const tests = [];
function test(name, fn) {
  tests.push([name, fn]);
}

function git(cwd, args) {
  execFileSync("git", args, { cwd, stdio: "pipe" });
}

/** A repo with sources, artifacts for them, and a manifest recorded at that state. */
function fixture({ sources, artifacts, writeManifest = true }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "prune-fixture-"));
  git(root, ["init", "-q", "."]);
  git(root, ["config", "user.email", "t@t"]);
  git(root, ["config", "user.name", "t"]);
  git(root, ["config", "commit.gpgsign", "false"]);

  for (const [filePath, contents] of Object.entries(sources)) {
    fs.mkdirSync(path.join(root, path.dirname(filePath)), { recursive: true });
    fs.writeFileSync(path.join(root, filePath), contents);
  }
  git(root, ["add", "-A"]);
  git(root, ["commit", "-qm", "sources"]);

  writeArtifacts(root, artifacts);

  const manifestPath = path.join(root, "l1-contracts/cache-forge/manifest.json");
  if (writeManifest) {
    execFileSync("node", [MANIFEST_WRITER, manifestPath], { cwd: root, stdio: "pipe" });
  }
  return { root, manifestPath };
}

/** artifacts: { "<artifact path>": "<compilationTarget source path>" } */
function writeArtifacts(root, artifacts) {
  for (const [artifactPath, sourcePath] of Object.entries(artifacts)) {
    const full = path.join(root, artifactPath);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    const name = path.basename(artifactPath, ".json");
    fs.writeFileSync(
      full,
      JSON.stringify({
        metadata: JSON.stringify({ settings: { compilationTarget: { [sourcePath]: name } } }),
      })
    );
  }
}

function prune(root, manifestPath) {
  const args = [SCRIPT];
  if (manifestPath) args.push("--manifest", manifestPath);
  args.push("l1-contracts:l1-contracts/out");
  return execFileSync("node", args, { cwd: root, encoding: "utf8" });
}

const survives = (root, artifactPath) => fs.existsSync(path.join(root, artifactPath));

// Forge names artifact directories after the source *basename*, and this repo has 58 duplicated
// basenames — so one directory holds artifacts from different sources and a basename comparison
// keeps stale ones alive.
test("prunes only the deleted source's artifacts when a basename is shared", () => {
  const { root, manifestPath } = fixture({
    sources: {
      "l1-contracts/contracts/bridge/ntv/L1NativeTokenVault.sol": "contract L1NativeTokenVault {}",
      "l1-contracts/test/foundry/NativeTokenVault/L1NativeTokenVault.sol": "contract L1NativeTokenVaultTest {}",
    },
    artifacts: {
      "l1-contracts/out/L1NativeTokenVault.sol/L1NativeTokenVault.json": "contracts/bridge/ntv/L1NativeTokenVault.sol",
      "l1-contracts/out/L1NativeTokenVault.sol/L1NativeTokenVaultTest.json":
        "test/foundry/NativeTokenVault/L1NativeTokenVault.sol",
    },
  });

  fs.rmSync(path.join(root, "l1-contracts/test/foundry/NativeTokenVault/L1NativeTokenVault.sol"));
  git(root, ["add", "-A"]);
  git(root, ["commit", "-qm", "delete the test source"]);

  prune(root, manifestPath);
  assert.equal(survives(root, "l1-contracts/out/L1NativeTokenVault.sol/L1NativeTokenVault.json"), true);
  assert.equal(survives(root, "l1-contracts/out/L1NativeTokenVault.sol/L1NativeTokenVaultTest.json"), false);
});

// The permanent-failure case: the artifact's target still resolves, so without the manifest it
// would be re-saved under every later SHA and fail check-hashes forever.
test("prunes artifacts of a source that changed, not just one that vanished", () => {
  const { root, manifestPath } = fixture({
    sources: { "l1-contracts/contracts/Pair.sol": "contract Kept {}\ncontract Removed {}\n" },
    artifacts: {
      "l1-contracts/out/Pair.sol/Kept.json": "contracts/Pair.sol",
      "l1-contracts/out/Pair.sol/Removed.json": "contracts/Pair.sol",
    },
  });

  fs.writeFileSync(path.join(root, "l1-contracts/contracts/Pair.sol"), "contract Kept {}\n");
  git(root, ["add", "-A"]);
  git(root, ["commit", "-qm", "remove one contract"]);

  prune(root, manifestPath);
  assert.equal(survives(root, "l1-contracts/out/Pair.sol/Removed.json"), false);
  assert.equal(survives(root, "l1-contracts/out/Pair.sol/Kept.json"), false, "the whole file recompiles");
});

test("keeps everything when nothing changed", () => {
  const { root, manifestPath } = fixture({
    sources: { "l1-contracts/contracts/A.sol": "contract A {}" },
    artifacts: { "l1-contracts/out/A.sol/A.json": "contracts/A.sol" },
  });

  prune(root, manifestPath);
  assert.equal(survives(root, "l1-contracts/out/A.sol/A.json"), true);
});

// Solidity also arrives through node_modules and remappings live in foundry.toml, so a dependency
// or config change can alter what compiles with every recorded .sol blob identical.
test("invalidates everything when a lock or config input changed", () => {
  for (const changed of ["yarn.lock", "l1-contracts/foundry.toml"]) {
    const { root, manifestPath } = fixture({
      sources: {
        "l1-contracts/contracts/A.sol": "contract A {}",
        "yarn.lock": 'resolved "1.0.0"\n',
        "l1-contracts/foundry.toml": '[profile.default]\nsolc_version = "0.8.28"\n',
      },
      artifacts: { "l1-contracts/out/A.sol/A.json": "contracts/A.sol" },
    });

    fs.writeFileSync(path.join(root, changed), "changed\n");
    git(root, ["add", "-A"]);
    git(root, ["commit", "-qm", `change ${changed}`]);

    prune(root, manifestPath);
    assert.equal(survives(root, "l1-contracts/out/A.sol/A.json"), false, changed);
  }
});

// This file decides whether artifacts are trusted, so anything it cannot vouch for must invalidate.
// `null` used to crash on .submodules; `{}` and a future version reported "nothing changed".
test("invalidates everything for a malformed or unsupported manifest", () => {
  const malformed = [
    "null",
    "{}",
    "[]",
    '"a string"',
    '{"version":2,"sources":{},"submodules":{}}',
    '{"version":1,"sources":null,"submodules":{}}',
    '{"version":1,"sources":{},"submodules":[]}',
    '{"version":1,"sources":{},"submodules":{},"configInputs":5}',
    "{not json at all",
  ];

  for (const body of malformed) {
    const { root, manifestPath } = fixture({
      sources: { "l1-contracts/contracts/A.sol": "contract A {}" },
      artifacts: { "l1-contracts/out/A.sol/A.json": "contracts/A.sol" },
    });
    fs.writeFileSync(manifestPath, body);

    const output = prune(root, manifestPath);
    assert.match(output, /treating the whole cache as stale/, body);
    assert.equal(survives(root, "l1-contracts/out/A.sol/A.json"), false, body);
  }
});

// A cache saved before the manifest existed must still work, just with less detection.
test("falls back to deletion-only detection with no manifest", () => {
  const { root } = fixture({
    sources: { "l1-contracts/contracts/A.sol": "contract A {}" },
    artifacts: {
      "l1-contracts/out/A.sol/A.json": "contracts/A.sol",
      "l1-contracts/out/Gone.sol/Gone.json": "contracts/Gone.sol",
    },
    writeManifest: false,
  });

  const output = prune(root, undefined);
  assert.match(output, /no source manifest/);
  assert.equal(survives(root, "l1-contracts/out/A.sol/A.json"), true);
  assert.equal(survives(root, "l1-contracts/out/Gone.sol/Gone.json"), false, "a vanished source is still caught");
});

// This repo commits generated artifact directories named after their source (zkstack-out/X.sol/), so
// an existence check alone would accept a directory as proof that a deleted source is still there.
test("does not accept a directory as proof that a source exists", () => {
  const { root, manifestPath } = fixture({
    sources: { "l1-contracts/zkstack-out/Migrator.sol/Migrator.json": "{}" },
    artifacts: { "l1-contracts/out/Migrator.sol/Migrator.json": "zkstack-out/Migrator.sol" },
  });

  prune(root, manifestPath);
  assert.equal(survives(root, "l1-contracts/out/Migrator.sol/Migrator.json"), false);
  assert.equal(survives(root, "l1-contracts/zkstack-out/Migrator.sol/Migrator.json"), true, "left alone");
});

test("leaves build-info alone", () => {
  const { root, manifestPath } = fixture({
    sources: { "l1-contracts/contracts/A.sol": "contract A {}" },
    artifacts: { "l1-contracts/out/A.sol/A.json": "contracts/A.sol" },
  });
  const buildInfo = path.join(root, "l1-contracts/out/build-info/abc.json");
  fs.mkdirSync(path.dirname(buildInfo), { recursive: true });
  fs.writeFileSync(buildInfo, JSON.stringify({ big: "compiler input" }));

  prune(root, manifestPath);
  assert.equal(fs.existsSync(buildInfo), true);
});

let failed = 0;
for (const [name, fn] of tests) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
  } catch (error) {
    failed++;
    console.error(`  ✗ ${name}`);
    console.error(`    ${error.message}`);
  }
}

console.log(`\n${tests.length - failed}/${tests.length} prune-stale-artifacts tests passed`);
if (failed > 0) {
  process.exit(1);
}
