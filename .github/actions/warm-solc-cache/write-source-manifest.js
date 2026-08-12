#!/usr/bin/env node

/**
 * Records the Solidity sources a cached build was produced from, so a later restore can tell which
 * of them have since changed.
 *
 * Deleted sources can be detected from the artifacts alone (their compilationTarget stops
 * resolving), but *modified* sources cannot: removing one contract from a file that still exists
 * leaves that contract's artifact behind with a target that still resolves. Forge does not prune
 * it, so the build re-saves it under the new SHA and every later commit restores it through the
 * prefix key — check-hashes and check-zkstack-out then fail on every commit, with no way to
 * self-heal. This manifest is what lets the restore side drop those artifacts.
 *
 * Identity comes from git blob hashes rather than file contents, so no hashing is needed here and
 * the comparison is exact. Submodules contribute their gitlink SHA: their sources are not listed in
 * the superproject, so a pin change is treated as invalidating everything.
 *
 * Tracked sources are not the whole compilation input. Solidity also arrives through node_modules
 * (the OpenZeppelin packages) and through remappings and solc settings in foundry.toml — none of
 * which are tracked .sol files. A dependency bump or a remapping change can therefore alter what
 * gets compiled while every recorded blob stays identical, and a contract removed from a dependency
 * source would leave a stale artifact that the prune keeps. The lock and config files that decide
 * those inputs are recorded too, and any change to them invalidates the whole cache; they change
 * rarely, so the cost of being blunt here is low.
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

// `git ls-files -s` prints: <mode> <object> <stage>\t<path>
const entries = git(["ls-files", "-s"])
  .split("\n")
  .filter(Boolean)
  .map((line) => {
    const [meta, filePath] = line.split("\t");
    const [mode, object] = meta.split(/\s+/);
    return { mode, object, filePath };
  });

const sources = entries.filter((e) => e.mode !== "160000" && e.filePath.endsWith(".sol"));
const submodules = entries.filter((e) => e.mode === "160000");

/**
 * Inputs that change what solc compiles without any tracked .sol changing: dependency resolution
 * (which supplies Solidity under node_modules) and the per-project foundry config, which carries
 * remappings, solc version and optimizer settings.
 */
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
