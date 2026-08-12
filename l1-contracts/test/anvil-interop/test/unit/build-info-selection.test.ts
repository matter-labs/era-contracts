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
import { allSourcePaths, selectBuildInfo } from "../../src/coverage/source-map-decoder";
import type { BuildInfo } from "../../src/coverage/source-map-decoder";

const tests: Array<[string, () => void]> = [];
function test(name: string, fn: () => void): void {
  tests.push([name, fn]);
}

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

test("picks the build-info whose numbering matches the artifact", () => {
  // A.sol is id 0 in the newer compilation and id 1 in the older one.
  assert.equal(selectBuildInfo(buildInfos, 0, "contracts/A.sol")?.file, "newer.json");
  assert.equal(selectBuildInfo(buildInfos, 1, "contracts/A.sol")?.file, "older.json");
  assert.equal(selectBuildInfo(buildInfos, 0, "contracts/B.sol")?.file, "older.json");
  assert.equal(selectBuildInfo(buildInfos, 1, "contracts/B.sol")?.file, "newer.json");
});

// The whole point: an artifact left over from the older compile must not be decoded with the newer
// map, which would attribute its lines to a different file.
test("does not hand an older artifact the newer map", () => {
  const selected = selectBuildInfo(buildInfos, 1, "contracts/A.sol");
  assert.equal(selected?.file, "older.json");
  assert.equal(selected?.sourceIdMap["1"], "contracts/A.sol");
  assert.notEqual(newer.sourceIdMap["1"], "contracts/A.sol", "the newer map disagrees, as expected");
});

test("returns null when nothing matches, so the caller can count it", () => {
  assert.equal(selectBuildInfo(buildInfos, 9, "contracts/A.sol"), null);
  assert.equal(selectBuildInfo(buildInfos, 0, "contracts/Unknown.sol"), null);
  assert.equal(selectBuildInfo([], 0, "contracts/A.sol"), null);
});

test("prefers the newest when both compilations agree", () => {
  const agreeing = [newer, { ...older, sourceIdMap: { "0": "contracts/A.sol" } }];
  assert.equal(selectBuildInfo(agreeing, 0, "contracts/A.sol")?.file, "newer.json");
});

test("unions the source paths across compilations", () => {
  const paths = allSourcePaths(buildInfos);
  assert.deepEqual([...paths].sort(), ["contracts/A.sol", "contracts/B.sol", "test/T.t.sol"]);
});

let failed = 0;
for (const [name, fn] of tests) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
  } catch (error) {
    failed++;
    console.error(`  ✗ ${name}`);
    console.error(`    ${(error as Error).message}`);
  }
}

console.log(`\n${tests.length - failed}/${tests.length} build-info-selection tests passed`);
if (failed > 0) {
  process.exit(1);
}
