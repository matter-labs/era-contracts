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
 * Deleting an artifact is not enough on its own. Forge tracks what it believes is compiled in
 * cache-forge/solidity-files-cache.json, and an entry there claiming an artifact this script just
 * deleted does not make forge recompile that one file — it discards its incremental plan and
 * rebuilds the whole project. Measured on l1-contracts:
 *
 *   one source edited, cache left coherent      ->  10.9s, 24 artifacts rewritten
 *   one artifact deleted, cache entry retained  ->  3m23s, all 1011 rewritten
 *
 * So every source whose artifacts went missing also loses its freshness entry, which is the state
 * forge is in for a file it has never seen: it recompiles that file and its dependents, and keeps
 * the rest. The invariant is checked against the disk rather than tracked alongside the deletions
 * above — the cache must never claim an artifact that is not there — so it cannot drift from the
 * pruning logic, and it covers artifacts dropped for having no compilationTarget too.
 *
 * Retained entries keep pointing at the build-info they were compiled under, which is what the
 * coverage collector resolves them through (see source-map-decoder.ts). Forge deletes a build-info
 * once no entry references it, so that lookup cannot outlive its target.
 *
 * Usage: node prune-stale-artifacts.js [--manifest <path>] <project-dir>:<artifacts-dir> [...]
 */

const fs = require("fs");
const path = require("path");

/** Forge's incremental-compilation bookkeeping, relative to a project directory. */
const FRESHNESS_CACHE = path.join("cache-forge", "solidity-files-cache.json");

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

/** Must match write-source-manifest.js, so an added config input is noticed here too. */
const CONFIG_INPUT_PATTERNS = [
  /^yarn\.lock$/,
  /(^|\/)foundry\.toml$/,
  /(^|\/)remappings\.txt$/,
  /(^|\/)package\.json$/,
];

function currentConfigInputs(blobs) {
  const inputs = {};
  for (const [filePath, object] of Object.entries(blobs)) {
    if (CONFIG_INPUT_PATTERNS.some((pattern) => pattern.test(filePath))) inputs[filePath] = object;
  }
  return inputs;
}

/**
 * Describes the first key that differs between two maps — added, removed or changed — or null when
 * they match. Both directions, so an added entry counts as drift.
 */
function firstDifference(recorded, current, label = "") {
  for (const key of new Set([...Object.keys(recorded), ...Object.keys(current)])) {
    if (recorded[key] === current[key]) continue;
    if (recorded[key] === undefined) return `${label}${key} was added`;
    if (current[key] === undefined) return `${label}${key} was removed`;
    return `${label}${key} changed`;
  }
  return null;
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
    // Deletion-only detection is not a safe fallback: a contract removed from a surviving file
    // leaves an artifact that this run would rebuild into a new cache *alongside a fresh manifest*,
    // which then vouches for it on every later commit. One cold rebuild ends that permanently.
    console.log("  no source manifest in the cache — treating the whole cache as stale");
    return { changed: new Set(), invalidateAll: true };
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
  //
  // Compared in both directions: walking only the recorded entries misses an *added* foundry.toml,
  // remappings.txt, lockfile or submodule, which is exactly a configuration change.
  const configDrift = firstDifference(manifest.configInputs || {}, currentConfigInputs(current.blobs));
  if (configDrift) {
    console.log(`  ${configDrift} since the cache was built — invalidating all artifacts`);
    return { changed: new Set(), invalidateAll: true };
  }

  const submoduleDrift = firstDifference(manifest.submodules || {}, current.submodules, "submodule ");
  if (submoduleDrift) {
    console.log(`  ${submoduleDrift} since the cache was built — invalidating all artifacts`);
    return { changed: new Set(), invalidateAll: true };
  }

  // Symmetric, like the config comparison above: walking only the recorded keys missed an *added*
  // .sol, and an added source is drift too.
  //
  // Only the drifted sources' artifacts are dropped, not the whole cache. Mixing artifacts from
  // different compilations used to corrupt coverage attribution — source IDs are numbered per
  // compilation — but the collector now matches each artifact to the build-info it was compiled
  // under (see selectBuildInfo), so incremental artifacts are safe to keep and the cache stays
  // useful on commits that touch Solidity.
  const changed = new Set();
  for (const key of new Set([...Object.keys(manifest.sources || {}), ...Object.keys(current.sources)])) {
    if ((manifest.sources || {})[key] !== current.sources[key]) changed.add(key);
  }
  if (changed.size > 0) {
    console.log(`  ${changed.size} source(s) added, changed or removed since the cache was built`);
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

/**
 * Drops every freshness entry whose recorded artifacts are no longer on disk, so forge treats those
 * sources as unseen and recompiles them incrementally instead of rebuilding the project.
 *
 * Entries are all-or-nothing: a file's contracts are compiled together, so keeping a partial entry
 * would tell forge some of them are still fresh.
 */
function pruneFreshnessCache(projectDir, artifactsDir, stale) {
  const stats = { entriesDropped: 0 };
  const cachePath = path.join(projectDir, FRESHNESS_CACHE);
  if (!fs.existsSync(cachePath)) return stats;

  // Nothing survived, so neither should the plan that describes it.
  if (stale.invalidateAll) {
    fs.rmSync(cachePath);
    console.log(`  removed ${cachePath} (no artifacts were kept)`);
    return stats;
  }

  let cache;
  try {
    cache = JSON.parse(fs.readFileSync(cachePath, "utf8"));
  } catch {
    // Unreadable bookkeeping cannot be reasoned about. Dropping it costs one full rebuild; trusting
    // it risks forge skipping a source whose artifact is missing.
    fs.rmSync(cachePath);
    console.log(`  removed ${cachePath} (unparsable)`);
    return stats;
  }

  if (!isPlainObject(cache) || !isPlainObject(cache.files)) {
    fs.rmSync(cachePath);
    console.log(`  removed ${cachePath} (unexpected shape)`);
    return stats;
  }

  for (const [sourcePath, entry] of Object.entries(cache.files)) {
    // { <contract>: { <solc version>: { <profile>: { path, build_id } } } }
    const recorded = [];
    for (const versions of Object.values(isPlainObject(entry?.artifacts) ? entry.artifacts : {})) {
      for (const profiles of Object.values(isPlainObject(versions) ? versions : {})) {
        for (const artifact of Object.values(isPlainObject(profiles) ? profiles : {})) {
          if (typeof artifact?.path === "string") recorded.push(artifact.path);
        }
      }
    }

    if (recorded.length === 0) continue;
    if (recorded.every((relative) => isFile(path.join(artifactsDir, relative)))) continue;

    delete cache.files[sourcePath];
    stats.entriesDropped++;
  }

  if (stats.entriesDropped > 0) {
    fs.writeFileSync(cachePath, JSON.stringify(cache));
    console.log(`  dropped ${stats.entriesDropped} freshness entr(ies) whose artifacts were pruned`);
  }

  return stats;
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

  // build-info is kept unless the whole cache is invalid: the collector selects the build-info each
  // artifact was compiled under, so several coexisting are fine — and deleting them on an
  // incremental build would leave it with no mapping for retained artifacts at all.
  if (stale.invalidateAll) {
    const buildInfo = path.join(artifactsDir, "build-info");
    if (fs.existsSync(buildInfo)) {
      fs.rmSync(buildInfo, { recursive: true });
      console.log(`  removed ${buildInfo} (the build will regenerate it for the current sources)`);
    }
  }

  for (const entry of fs.readdirSync(artifactsDir, { withFileTypes: true })) {
    // Anything left in build-info at this point matches the artifacts beside it.
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

      if (stale.invalidateAll) {
        fs.rmSync(artifactPath);
        stats.removed++;
        continue;
      }

      // Repo-relative, to compare against the manifest's keys.
      const repoRelative = path.relative(process.cwd(), path.resolve(projectDir, sourcePath));

      if (stale.changed.has(repoRelative)) {
        console.log(`  pruning ${artifactPath} (source drifted: ${repoRelative})`);
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

const totals = { removed: 0, kept: 0, unattributed: 0, dirsRemoved: 0, entriesDropped: 0 };
for (const target of targets) {
  const [projectDir, artifactsDir] = target.split(":");
  if (!projectDir || !artifactsDir) {
    console.error(`Malformed target "${target}", expected <project-dir>:<artifacts-dir>`);
    process.exit(1);
  }
  const stats = prune(projectDir, artifactsDir, stale);
  // After the artifacts are gone, so the disk is the source of truth for what forge may still claim.
  Object.assign(stats, pruneFreshnessCache(projectDir, artifactsDir, stale));
  for (const key of Object.keys(totals)) totals[key] += stats[key] ?? 0;
}

console.log(
  `Pruned ${totals.removed} stale artifact(s) and ${totals.dirsRemoved} empty director(ies); ` +
    `kept ${totals.kept}` +
    (totals.unattributed > 0 ? `; ${totals.unattributed} had no compilationTarget and were dropped` : "") +
    (totals.entriesDropped > 0 ? `; ${totals.entriesDropped} freshness entr(ies) dropped` : "")
);
