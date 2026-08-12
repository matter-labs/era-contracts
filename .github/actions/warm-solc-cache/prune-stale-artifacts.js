#!/usr/bin/env node

/**
 * Deletes artifacts whose source file no longer exists, so a restored cache cannot leave stale
 * entries for a contract the current commit deleted. `calculate-hashes` and `forge build --sizes`
 * both enumerate the artifact directories, so a survivor there fails CI on the commit that
 * removed the contract — the exact case this exists to prevent.
 *
 * Matching is per artifact, on the full source path from `metadata.settings.compilationTarget`,
 * not on the directory basename. Forge names artifact directories after the source *basename*,
 * and this repo has 58 duplicated basenames, so one directory can hold artifacts from different
 * sources:
 *
 *   out/L1NativeTokenVault.sol/L1NativeTokenVault.json      <- contracts/bridge/ntv/L1NativeTokenVault.sol
 *   out/L1NativeTokenVault.sol/L1NativeTokenVaultTest.json  <- test/foundry/.../L1NativeTokenVault.sol
 *
 * Deleting either source leaves the other basename present, so a basename comparison would keep
 * the whole directory and its stale artifacts with it.
 *
 * Over-pruning is harmless — forge recompiles whatever is missing.
 *
 * A deleted source is only half the problem. Removing one *contract* from a file that still exists
 * leaves that contract's artifact behind with a target that still resolves — and because the build
 * then re-saves it under the new SHA, every later commit restores it through the prefix key, so
 * check-hashes and check-zkstack-out would fail forever with no way to self-heal. So when the cache
 * carries a source manifest (see write-source-manifest.js), artifacts of *modified* sources are
 * dropped too, by comparing git blob hashes. A changed submodule pin invalidates everything, since
 * submodule sources are not listed in the superproject.
 *
 * Without a manifest (a cache from before this existed) only deletions are detectable, which is the
 * old behaviour rather than a regression.
 *
 * Usage: node prune-stale-artifacts.js [--manifest <path>] <project-dir>:<artifacts-dir> [...]
 */

const fs = require("fs");
const path = require("path");

const { execFileSync } = require("child_process");

/** Current blob hashes for tracked sources and submodule pins, in the manifest's shape. */
function currentGitState() {
  const out = execFileSync("git", ["ls-files", "-s"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const sources = {};
  const submodules = {};
  const blobs = {};
  for (const line of out.split("\n")) {
    if (!line) continue;
    const [meta, filePath] = line.split("\t");
    const [mode, object] = meta.split(/\s+/);
    if (mode === "160000") submodules[filePath] = object;
    else {
      blobs[filePath] = object;
      if (filePath.endsWith(".sol")) sources[filePath] = object;
    }
  }
  return { sources, submodules, blobs };
}

/** Manifest versions this reader understands; anything else is not trusted. */
const SUPPORTED_MANIFEST_VERSIONS = new Set([1]);

const isPlainObject = (value) => typeof value === "object" && value !== null && !Array.isArray(value);

/** Describes what is wrong with a manifest, or null when it is usable. */
function validateManifest(manifest) {
  if (!isPlainObject(manifest)) return "is not an object";
  if (!SUPPORTED_MANIFEST_VERSIONS.has(manifest.version))
    return `has unsupported version ${JSON.stringify(manifest.version)}`;
  for (const field of ["sources", "submodules"]) {
    if (!isPlainObject(manifest[field])) return `has no usable "${field}" map`;
  }
  // configInputs arrived later than version 1's first shape, so treat it as optional but typed.
  if (manifest.configInputs !== undefined && !isPlainObject(manifest.configInputs)) {
    return 'has a malformed "configInputs" map';
  }
  return null;
}

/**
 * Source paths (repo-relative) whose contents differ from what the cache was built from, or
 * `"*"` when a submodule pin moved and nothing can be trusted. Empty when there is no manifest.
 */
function staleSources(manifestPath) {
  if (!manifestPath || !fs.existsSync(manifestPath)) {
    console.log("  no source manifest in the cache — only deleted sources can be detected");
    return { changed: new Set(), invalidateAll: false };
  }

  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch {
    console.log("  source manifest unreadable — treating the whole cache as stale");
    return { changed: new Set(), invalidateAll: true };
  }

  // This file decides whether restored artifacts are trusted, so anything it cannot vouch for is
  // treated as untrustworthy. Valid JSON is not enough: `null` used to crash on .submodules, and
  // `{}` or a manifest from a future writer would report "nothing changed" and keep every stale
  // artifact — the quiet failure this whole mechanism exists to prevent.
  const problem = validateManifest(manifest);
  if (problem) {
    console.log(`  source manifest ${problem} — treating the whole cache as stale`);
    return { changed: new Set(), invalidateAll: true };
  }

  const current = currentGitState();

  // Dependency resolution and foundry config decide what solc compiles, so a change to either can
  // invalidate artifacts without any tracked .sol changing — including a contract disappearing from
  // a dependency source, which the per-source comparison below cannot see.
  for (const [inputPath, blob] of Object.entries(manifest.configInputs || {})) {
    if (current.blobs[inputPath] !== blob) {
      console.log(`  ${inputPath} changed since the cache was built — invalidating all artifacts`);
      return { changed: new Set(), invalidateAll: true };
    }
  }

  for (const [submodule, pin] of Object.entries(manifest.submodules || {})) {
    if (current.submodules[submodule] !== pin) {
      console.log(`  submodule ${submodule} moved since the cache was built — invalidating all artifacts`);
      return { changed: new Set(), invalidateAll: true };
    }
  }

  const changed = new Set();
  for (const [sourcePath, blob] of Object.entries(manifest.sources || {})) {
    if (current.sources[sourcePath] !== blob) changed.add(sourcePath);
  }
  if (changed.size > 0) {
    console.log(`  ${changed.size} source(s) changed since the cache was built`);
  }
  return { changed, invalidateAll: false };
}

function isFile(candidate) {
  try {
    return fs.statSync(candidate).isFile();
  } catch {
    return false;
  }
}

/** Reads the compilation target source path out of an artifact, or null if it has none. */
function sourcePathOf(artifactPath) {
  let artifact;
  try {
    artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  } catch {
    return null;
  }

  const raw = artifact.metadata ?? artifact.rawMetadata;
  if (!raw) return null;

  let metadata;
  try {
    metadata = typeof raw === "string" ? JSON.parse(raw) : raw;
  } catch {
    return null;
  }

  const target = metadata?.settings?.compilationTarget;
  if (!target) return null;

  // { "<source path>": "<contract name>" } — one entry per artifact.
  const [sourcePath] = Object.keys(target);
  return sourcePath || null;
}

function prune(projectDir, artifactsDir, stale) {
  const stats = { removed: 0, kept: 0, unattributed: 0, dirsRemoved: 0 };
  if (!fs.existsSync(artifactsDir)) return stats;

  // Cache existence checks: many artifacts share a source (one file, several contracts).
  const sourceExists = new Map();
  const exists = (sourcePath) => {
    if (!sourceExists.has(sourcePath)) {
      // Must be a *file*: this repo commits generated artifact directories named after their
      // source (zkstack-out/L2MessageRoot.sol/ and friends), so an existence check alone would
      // accept a directory as proof that a deleted source is still present.
      sourceExists.set(sourcePath, isFile(path.resolve(projectDir, sourcePath)));
    }
    return sourceExists.get(sourcePath);
  };

  for (const entry of fs.readdirSync(artifactsDir, { withFileTypes: true })) {
    // build-info holds compiler input/output, not per-contract artifacts, and nothing enumerates
    // it for hashes or sizes.
    if (!entry.isDirectory() || entry.name === "build-info") continue;

    const dir = path.join(artifactsDir, entry.name);
    for (const file of fs.readdirSync(dir)) {
      if (!file.endsWith(".json")) continue;
      const artifactPath = path.join(dir, file);
      const sourcePath = sourcePathOf(artifactPath);

      if (sourcePath === null) {
        // Cannot attribute it, so cannot prove its source still exists. Drop it and let forge
        // rebuild — losing a little cache beats keeping an artifact we cannot account for.
        fs.rmSync(artifactPath);
        stats.unattributed++;
        stats.removed++;
        continue;
      }

      // Source paths in artifacts are project-relative; the manifest is repo-relative.
      const repoRelative = path.relative(process.cwd(), path.resolve(projectDir, sourcePath));

      if (stale.invalidateAll) {
        fs.rmSync(artifactPath);
        stats.removed++;
        continue;
      }

      if (stale.changed.has(repoRelative)) {
        console.log(`  pruning ${artifactPath} (source changed: ${repoRelative})`);
        fs.rmSync(artifactPath);
        stats.removed++;
      } else if (exists(sourcePath)) {
        stats.kept++;
      } else {
        console.log(`  pruning ${artifactPath} (source gone: ${sourcePath})`);
        fs.rmSync(artifactPath);
        stats.removed++;
      }
    }

    if (fs.readdirSync(dir).length === 0) {
      fs.rmSync(dir, { recursive: true });
      stats.dirsRemoved++;
    }
  }

  return stats;
}

const argv = process.argv.slice(2);
let manifestPath;
const targets = [];
// Walked rather than filtered by index: with no --manifest, `indexOf` returns -1 and an
// index-based filter drops argv[0] — the only target — leaving the documented no-manifest
// invocation printing usage instead of running.
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--manifest") {
    manifestPath = argv[i + 1];
    i++;
    continue;
  }
  if (argv[i].startsWith("--")) continue;
  targets.push(argv[i]);
}
if (targets.length === 0) {
  console.error("Usage: node prune-stale-artifacts.js [--manifest <path>] <project-dir>:<artifacts-dir> [...]");
  process.exit(1);
}

const stale = staleSources(manifestPath);

const totals = { removed: 0, kept: 0, unattributed: 0, dirsRemoved: 0 };
for (const target of targets) {
  const [projectDir, artifactsDir] = target.split(":");
  if (!projectDir || !artifactsDir) {
    console.error(`Malformed target "${target}", expected <project-dir>:<artifacts-dir>`);
    process.exit(1);
  }
  const stats = prune(projectDir, artifactsDir, stale);
  for (const key of Object.keys(totals)) totals[key] += stats[key];
}

console.log(
  `Pruned ${totals.removed} stale artifact(s) and ${totals.dirsRemoved} empty director(ies); ` +
    `kept ${totals.kept}` +
    (totals.unattributed > 0 ? `; ${totals.unattributed} had no compilationTarget and were dropped` : "")
);
