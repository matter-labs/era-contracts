#!/usr/bin/env node
// @ts-check

/**
 * Drops restored artifacts that the current commit's sources no longer justify, so `calculate-hashes`
 * and `forge build --sizes` — both of which enumerate artifact directories — cannot fail on a
 * survivor from an older build. Over-pruning is harmless; forge recompiles whatever is missing.
 *
 * Three rules, each covering a case the previous one misses:
 *
 * 1. Match per artifact on `metadata.settings.compilationTarget`, never on the directory basename.
 *    Forge names directories after the source basename and this repo has 58 duplicates, so
 *    out/L1NativeTokenVault.sol/ holds artifacts from both the contract and a test file.
 * 2. Drop artifacts of *modified* sources too, by git blob hash against the manifest
 *    (write-source-manifest.js). A contract removed from a surviving file otherwise leaves an
 *    artifact whose target still resolves, which the build re-saves and every later commit
 *    restores — check-hashes then fails forever with no way to self-heal. No manifest, an
 *    unreadable one, or a moved submodule pin invalidates everything.
 * 3. Drop the freshness entry of anything deleted. Forge reads
 *    cache-forge/solidity-files-cache.json to decide what is compiled, and an entry claiming a
 *    deleted artifact makes it abandon incremental compilation: measured on l1-contracts, one
 *    edited source costs 10.9s and 24 artifacts with the entry dropped, against 3m23s and all
 *    1011 with it retained. The invariant is checked against the disk — the cache must never claim
 *    an artifact that is not there — so it cannot drift from the rules above.
 *
 * Retained entries keep pointing at the build-info they were compiled under, which is how the
 * coverage collector decodes them (source-map-decoder.ts).
 *
 * Usage: node prune-stale-artifacts.js [--manifest <path>] <project-dir>:<artifacts-dir> [...]
 */

const fs = require("fs");
const path = require("path");

/** Forge's incremental-compilation bookkeeping, relative to a project directory. */
const FRESHNESS_CACHE = path.join("cache-forge", "solidity-files-cache.json");

const { execFileSync } = require("child_process");

/**
 * Current blob hashes for tracked sources and submodule pins, in the manifest's shape.
 *
 * -z for the same reason write-source-manifest.js uses it: git quotes non-ASCII paths, and a quoted
 * key matches nothing on disk, so drift in such a file would be invisible here too. Both sides must
 * agree, and both must agree with the filesystem.
 */
function currentGitState() {
  const out = execFileSync("git", ["ls-files", "-sz"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const sources = {};
  const submodules = {};
  const blobs = {};
  for (const record of out.split("\0")) {
    if (!record) continue;
    const [meta, filePath] = record.split("\t");
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
    // Deletion-only detection is not a safe fallback: the rebuilt cache would carry a fresh manifest
    // vouching for a stale artifact on every later commit. One cold rebuild ends that permanently.
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

  // Valid JSON is not enough: `null` crashed on .submodules, and `{}` or a future writer's shape
  // would report "nothing changed" and keep every stale artifact.
  const problem = validateManifest(manifest);
  if (problem) {
    console.log(`  source manifest ${problem} — treating the whole cache as stale`);
    return { changed: new Set(), invalidateAll: true };
  }

  const current = currentGitState();

  // Dependency resolution and foundry config change what solc compiles without any tracked .sol
  // changing. Compared in both directions, so an *added* config file counts as drift too.
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

  // Symmetric for the same reason as the config comparison. Only the drifted sources' artifacts go:
  // mixing compilations is safe because the collector decodes each artifact through the build-info
  // its freshness entry records (source-map-decoder.ts).
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
    // Dropping it costs one full rebuild; trusting it risks forge skipping a missing artifact.
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
      // Must be a *file*: this repo commits directories named after sources (zkstack-out/X.sol/),
      // so a bare existence check would accept one as proof that a deleted source survives.
      sourceExists.set(sourcePath, isFile(path.resolve(projectDir, sourcePath)));
    }
    return sourceExists.get(sourcePath);
  };

  // build-info survives unless everything is invalid: several coexisting are fine, and deleting them
  // would leave retained artifacts with no source map at all.
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
        // Unattributable, so unprovable. Drop it and let forge rebuild.
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
// Walked, not index-filtered: with no --manifest, `indexOf` returns -1 and dropped argv[0].
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
