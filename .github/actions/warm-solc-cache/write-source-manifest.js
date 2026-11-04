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
const { readGitState } = require("./git-source-state");

const outputPath = process.argv[2];
if (!outputPath) {
  console.error("Usage: node write-source-manifest.js <output-path>");
  process.exit(1);
}

const { sources, submodules, configInputs } = readGitState();

// A change to a submodule pin or a config input invalidates the whole cache; a changed source
// invalidates only its own artifacts.
const manifest = { version: 1, sources, submodules, configInputs };

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, JSON.stringify(manifest));
console.log(
  `Recorded ${Object.keys(sources).length} Solidity sources, ${Object.keys(submodules).length} ` +
    `submodule pins and ${Object.keys(configInputs).length} lock/config inputs in ${outputPath}`
);
