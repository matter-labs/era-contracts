/**
 * Unit tests for matching an artifact to the build-info it was compiled under.
 *
 * Source IDs are numbered per compilation, so a build is only decodable with its own map: across two
 * real build-info files in this repo, 224 IDs appear in both and 223 of them point at different
 * files. Foundry records no build id on artifacts, but an artifact's own source id plus its
 * compilation target agree only with the map it came from — which is what makes this recoverable,
 * and what lets the artifact cache stay warm without corrupting coverage attribution.
 *
 * Run with: yarn test:build-info
 */

import * as assert from "assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { allSourcePaths, buildInfoById, loadArtifactBuildIds } from "../../src/coverage/source-map-decoder";
import type { BuildInfo } from "../../src/coverage/source-map-decoder";
import { createSuite } from "./harness";

const { test, run } = createSuite("build-info-selection");

// Two compilations of an overlapping source set, numbered independently — the real situation.
const newer: BuildInfo = {
  file: "newer.json",
  mtimeMs: 2000,
  sourceIdMap: { "0": "contracts/A.sol", "1": "contracts/B.sol", "2": "test/T.t.sol" },
};
const older: BuildInfo = {
  file: "older.json",
  mtimeMs: 1000,
  sourceIdMap: { "0": "contracts/B.sol", "1": "contracts/A.sol" },
};
const buildInfos = [newer, older]; // newest first, as loadBuildInfos returns them

// Forge's own linkage, which is exact. The heuristic this replaced — find the build-info whose map
// sends the artifact's source id to its compilation target — was unsound: a build-info saying
// `0 -> A` does not say A was its target, so old `{0:A, 1:B}` and new `{0:A, 1:C}` both "match" an
// old A artifact, and its references to id 1 then resolve to C. Selection looked successful, so
// nothing was flagged and the coverage report was skewed silently.
test("resolves an artifact to its build-info by forge's recorded build_id", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "build-id-"));
  fs.mkdirSync(path.join(root, "cache-forge"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "cache-forge/solidity-files-cache.json"),
    JSON.stringify({
      files: {
        "contracts/A.sol": {
          artifacts: { A: { "0.8.28": { default: { path: "A.sol/A.json", build_id: "older" } } } },
        },
        "contracts/C.sol": {
          artifacts: { C: { "0.8.28": { default: { path: "C.sol/C.json", build_id: "newer" } } } },
        },
      },
    })
  );

  const buildIds = loadArtifactBuildIds(root);
  assert.equal(buildIds.get("A.sol/A.json"), "older", "the old artifact keeps its own build");
  assert.equal(buildIds.get("C.sol/C.json"), "newer");
  assert.equal(buildIds.get("Absent.sol/Absent.json"), undefined);

  // ...and the id selects that build-info, not merely one that happens to agree on an entry.
  assert.equal(buildInfoById(buildInfos, "older")?.file, "older.json");
  assert.equal(buildInfoById(buildInfos, "newer")?.file, "newer.json");
  assert.equal(buildInfoById(buildInfos, "gone"), null, "caller must handle a missing build-info");
});

test("survives a missing or malformed forge cache without inventing a linkage", () => {
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), "no-cache-"));
  assert.equal(loadArtifactBuildIds(empty).size, 0);

  const broken = fs.mkdtempSync(path.join(os.tmpdir(), "bad-cache-"));
  fs.mkdirSync(path.join(broken, "cache-forge"), { recursive: true });
  fs.writeFileSync(path.join(broken, "cache-forge/solidity-files-cache.json"), "{not json");
  assert.equal(loadArtifactBuildIds(broken).size, 0, "callers treat an empty map as unresolved");
});

test("unions the source paths across compilations", () => {
  const paths = allSourcePaths(buildInfos);
  assert.deepEqual([...paths].sort(), ["contracts/A.sol", "contracts/B.sol", "test/T.t.sol"]);
});

run();
