// @ts-check

/**
 * The manifest's input definition, in one place.
 *
 * write-source-manifest.js records these and prune-stale-artifacts.js compares against them, so the
 * two must agree exactly. When they did not — each file carrying its own copy under a comment saying
 * they must match — the failure was silent and one-directional: an input the writer records but the
 * comparison ignores makes the prune report "nothing changed" and keep stale artifacts, which is the
 * failure the manifest exists to prevent. No fixture catches it either, since each drives both
 * scripts from the same commit.
 *
 * Plain CommonJS with no dependencies: both callers run as `node <script>.js` from a composite
 * action, in workflows that have not installed node_modules yet.
 */

const { execFileSync } = require("child_process");

/** Inputs that change what solc compiles without any tracked .sol changing. */
const CONFIG_INPUT_PATTERNS = [
  /^yarn\.lock$/,
  /(^|\/)foundry\.toml$/,
  /(^|\/)remappings\.txt$/,
  /(^|\/)package\.json$/,
];

const SUBMODULE_MODE = "160000";

/**
 * Every tracked entry, as `{ mode, object, filePath }`.
 *
 * `git ls-files -sz` prints: <mode> <object> <stage>\t<path>\0
 *
 * -z is load-bearing: without it git quotes non-ASCII paths, so `contracts/Ünicode.sol` arrives as
 * `"contracts/\303\234nicode.sol"` — a key matching nothing on disk that does not even end in
 * `.sol`, making such a file invisible to drift detection.
 */
function trackedEntries() {
  const out = execFileSync("git", ["ls-files", "-sz"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  return out
    .split("\0")
    .filter(Boolean)
    .map((record) => {
      const [meta, filePath] = record.split("\t");
      const [mode, object] = meta.split(/\s+/);
      return { mode, object, filePath };
    });
}

/**
 * Blob hashes keyed by path, split the way the manifest stores them: Solidity sources, submodule
 * gitlink SHAs, and the lock/config inputs above.
 */
function readGitState() {
  const sources = {};
  const submodules = {};
  const configInputs = {};

  for (const { mode, object, filePath } of trackedEntries()) {
    if (mode === SUBMODULE_MODE) {
      submodules[filePath] = object;
      continue;
    }
    if (filePath.endsWith(".sol")) sources[filePath] = object;
    if (CONFIG_INPUT_PATTERNS.some((pattern) => pattern.test(filePath))) configInputs[filePath] = object;
  }

  return { sources, submodules, configInputs };
}

module.exports = { readGitState, CONFIG_INPUT_PATTERNS, SUBMODULE_MODE };
