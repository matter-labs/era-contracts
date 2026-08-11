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
 * Known limit: removing a *contract* from a source file that still exists leaves that contract's
 * artifact behind, since its compilationTarget still resolves. Forge does not prune those either,
 * and nothing here can see it without compiling. Such a mismatch fails loudly in check-hashes
 * rather than passing quietly, and `enabled: false` gives a from-scratch build.
 *
 * Usage: node prune-stale-artifacts.js <project-dir>:<artifacts-dir> [...]
 */

const fs = require("fs");
const path = require("path");

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

function prune(projectDir, artifactsDir) {
  const stats = { removed: 0, kept: 0, unattributed: 0, dirsRemoved: 0 };
  if (!fs.existsSync(artifactsDir)) return stats;

  // Cache existence checks: many artifacts share a source (one file, several contracts).
  const sourceExists = new Map();
  const exists = (sourcePath) => {
    if (!sourceExists.has(sourcePath)) {
      sourceExists.set(sourcePath, fs.existsSync(path.resolve(projectDir, sourcePath)));
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

      if (exists(sourcePath)) {
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

const targets = process.argv.slice(2);
if (targets.length === 0) {
  console.error("Usage: node prune-stale-artifacts.js <project-dir>:<artifacts-dir> [...]");
  process.exit(1);
}

const totals = { removed: 0, kept: 0, unattributed: 0, dirsRemoved: 0 };
for (const target of targets) {
  const [projectDir, artifactsDir] = target.split(":");
  if (!projectDir || !artifactsDir) {
    console.error(`Malformed target "${target}", expected <project-dir>:<artifacts-dir>`);
    process.exit(1);
  }
  const stats = prune(projectDir, artifactsDir);
  for (const key of Object.keys(totals)) totals[key] += stats[key];
}

console.log(
  `Pruned ${totals.removed} stale artifact(s) and ${totals.dirsRemoved} empty director(ies); ` +
    `kept ${totals.kept}` +
    (totals.unattributed > 0 ? `; ${totals.unattributed} had no compilationTarget and were dropped` : "")
);
