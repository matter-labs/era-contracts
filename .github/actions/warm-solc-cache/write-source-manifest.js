#!/usr/bin/env node
// @ts-check

/**
 * Records the Solidity sources a cached build was produced from, so a later restore can tell which
 * have since changed. Deleted sources are detectable from the artifacts alone, but a *modified* one
 * is not: removing a contract from a surviving file leaves an artifact whose target still resolves,
 * which the build re-saves and every later commit restores — check-hashes then fails forever.
 *
 * Identity is the git blob hash, so the comparison is exact and nothing needs hashing here.
 * Submodules contribute their gitlink SHA, and the lock/config files that decide what solc compiles
 * (node_modules resolution, remappings, solc settings) are recorded too; a change to either
 * invalidates everything, which is blunt but they change rarely.
 *
 * Usage: node write-source-manifest.js <output-path>
 */

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

function git(args) {
  return execFileSync("git", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

const outputPath = process.argv[2];
if (!outputPath) {
  console.error("Usage: node write-source-manifest.js <output-path>");
  process.exit(1);
}

// `git ls-files -sz` prints: <mode> <object> <stage>\t<path>\0
//
// -z is load-bearing: without it git quotes non-ASCII paths, so `contracts/Ünicode.sol` arrives as
// `"contracts/\303\234nicode.sol"` — a key matching nothing on disk that does not even end in
// `.sol`, making such a file invisible to drift detection.
const entries = git(["ls-files", "-sz"])
  .split("\0")
  .filter(Boolean)
  .map((record) => {
    const [meta, filePath] = record.split("\t");
    const [mode, object] = meta.split(/\s+/);
    return { mode, object, filePath };
  });

const sources = entries.filter((e) => e.mode !== "160000" && e.filePath.endsWith(".sol"));
const submodules = entries.filter((e) => e.mode === "160000");

/** Inputs that change what solc compiles without any tracked .sol changing. */
const CONFIG_INPUT_PATTERNS = [
  /^yarn\.lock$/,
  /(^|\/)foundry\.toml$/,
  /(^|\/)remappings\.txt$/,
  /(^|\/)package\.json$/,
];
const configInputs = entries.filter(
  (e) => e.mode !== "160000" && CONFIG_INPUT_PATTERNS.some((pattern) => pattern.test(e.filePath))
);

const manifest = {
  version: 1,
  // blob hash per tracked Solidity source
  sources: Object.fromEntries(sources.map((e) => [e.filePath, e.object])),
  // gitlink SHA per submodule; a change here invalidates the whole cache
  submodules: Object.fromEntries(submodules.map((e) => [e.filePath, e.object])),
  // lock and config inputs; a change here also invalidates the whole cache
  configInputs: Object.fromEntries(configInputs.map((e) => [e.filePath, e.object])),
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, JSON.stringify(manifest));
console.log(
  `Recorded ${sources.length} Solidity sources, ${submodules.length} submodule pins and ` +
    `${configInputs.length} lock/config inputs in ${outputPath}`
);
