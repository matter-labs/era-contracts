/**
 * Unit tests for the governance-bundle checks the upgrade runners apply to a merged prepare output
 * (`src/helpers/governance-bundle.ts`): reading the one `[governance_calls] calls` bundle, exact
 * call-for-call comparison, and the direct upgrade legs — recovering them from a bundle, holding
 * them to the canonical contiguous order (core -> CTM infrastructure -> CTM transition), and the
 * recurring registry hop's legs-only shape.
 *
 * The helpers compare targets, selectors and calldata bytes and never decode against an ABI, so
 * the selectors here are opaque 4-byte tags standing in for the executor entrypoints.
 *
 * Run with: yarn test:unit governance-bundle
 */

import * as assert from "assert/strict";
import { ethers } from "ethers";
import type {
  ExpectedCall,
  MergedGovernanceOutput,
  UpgradeLeg,
  UpgradeLegSelectors,
} from "../../src/helpers/governance-bundle";
import {
  assertBundleIs,
  assertRegistryHopBundle,
  assertUpgradeLegs,
  decodeGovernanceCalls,
  encodeGovernanceCalls,
  governanceCallsOf,
  recoverUpgradeLegs,
  upgradeLegsOf,
} from "../../src/helpers/governance-bundle";
import { createSuite } from "./harness";

const { test, run } = createSuite("governance-bundle");

const address = (n: number) => ethers.utils.getAddress(ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 20));

const CORE_EXECUTOR = address(0xc0);
const CTM_EXECUTOR = address(0xc1);
const CORE_TRANSITION = address(0x0a);
const CTM_INFRASTRUCTURE = address(0x0b);
const CTM_TRANSITION = address(0x0c);
const STRANGER = address(0x99);

// Stand-ins for the three entrypoint selectors.
const SELECTORS: UpgradeLegSelectors = {
  core: "0x11111111",
  ctmInfrastructure: "0x22222222",
  ctmTransition: "0x33333333",
};
const OTHER_SELECTOR = "0x44444444";

const CORE_LEG: UpgradeLeg = { kind: "core", executor: CORE_EXECUTOR, object: CORE_TRANSITION };
const INFRASTRUCTURE_LEG: UpgradeLeg = {
  kind: "ctmInfrastructure",
  executor: CTM_EXECUTOR,
  object: CTM_INFRASTRUCTURE,
};
const TRANSITION_LEG: UpgradeLeg = { kind: "ctmTransition", executor: CTM_EXECUTOR, object: CTM_TRANSITION };
const ALL_LEGS = [CORE_LEG, INFRASTRUCTURE_LEG, TRANSITION_LEG];

/** `selector(address)` calldata. */
const callData = (selector: string, argument: string) =>
  ethers.utils.hexConcat([selector, ethers.utils.hexZeroPad(argument, 32)]);

/** The call that applies `leg`. */
const legCall = (leg: UpgradeLeg) => ({ target: leg.executor, data: callData(SELECTORS[leg.kind], leg.object) });

/** An unrelated call (an external action) in a bundle. */
const OTHER_CALL = { target: STRANGER, data: callData(OTHER_SELECTOR, STRANGER) };

const CORE_CALL: ExpectedCall = { label: "core leg", ...legCall(CORE_LEG) };

function merged(
  calls: Array<{ target: string; value?: number; data: string }>,
  externalActions: MergedGovernanceOutput["external_actions"] = []
): MergedGovernanceOutput {
  return { governance_calls: { calls: encodeGovernanceCalls(calls) }, external_actions: externalActions };
}

test("a bundle round-trips through abi.encode(Call[]); an empty bundle decodes to no calls", () => {
  const calls = decodeGovernanceCalls(
    encodeGovernanceCalls([legCall(CORE_LEG), { target: STRANGER, value: 7, data: "0x" }])
  );
  assert.equal(calls.length, 2);
  assert.equal(calls[0].target, CORE_EXECUTOR);
  assert.equal(calls[0].data, legCall(CORE_LEG).data.toLowerCase());
  assert.ok(calls[1].value.eq(7));
  assert.deepEqual(decodeGovernanceCalls("0x"), []);
  assert.deepEqual(decodeGovernanceCalls(encodeGovernanceCalls([])), []);
});

test("the bundle is read from `calls`; the per-stage keys of the old format are refused", () => {
  assert.equal(governanceCallsOf(merged([legCall(CORE_LEG)])).length, 1);
  const staged = { governance_calls: { stage0_calls: "0x", stage1_calls: "0x", stage2_calls: "0x" } };
  assert.throws(() => governanceCallsOf(staged), /keys other than `calls`: stage0_calls, stage1_calls, stage2_calls/);
  assert.throws(() => governanceCallsOf({}), /no \[governance_calls\] table/);
  assert.throws(() => governanceCallsOf({ governance_calls: {} }), /calls is missing/);
});

test("an identical bundle passes, with addresses compared case-insensitively", () => {
  const calls = governanceCallsOf(merged([legCall(CORE_LEG)]));
  assertBundleIs(calls, [{ ...CORE_CALL, target: CORE_EXECUTOR.toLowerCase() }], "bundle");
});

test("a reordered, shortened, extended or re-valued bundle is refused, naming the slot", () => {
  const a: ExpectedCall = { label: "first", target: address(1), data: "0xaa" };
  const b: ExpectedCall = { label: "second", target: address(2), data: "0xbb" };
  const decode = (calls: ExpectedCall[]) => decodeGovernanceCalls(encodeGovernanceCalls(calls));
  assert.throws(() => assertBundleIs(decode([b, a]), [a, b], "bundle"), /\[0\] expected first/);
  assert.throws(() => assertBundleIs(decode([a]), [a, b], "bundle"), /\[1\] missing: second/);
  assert.throws(() => assertBundleIs(decode([a, b, a]), [a, b], "bundle"), /\[2\] unexpected/);
  assert.throws(() => assertBundleIs(decode([a, { ...b, value: 1 }]), [a, b], "bundle"), /\[1\] expected second/);
});

// ── Upgrade legs ──

test("the reported legs are the nonzero objects, in canonical order, each on its domain's executor", () => {
  const all = upgradeLegsOf({
    coreTransition: CORE_TRANSITION,
    coreExecutor: CORE_EXECUTOR,
    ctmInfrastructureTransition: CTM_INFRASTRUCTURE,
    ctmTransition: CTM_TRANSITION,
    ctmExecutor: CTM_EXECUTOR,
  });
  assert.deepEqual(all, ALL_LEGS);
  const transitionOnly = upgradeLegsOf({
    coreTransition: ethers.constants.AddressZero,
    coreExecutor: CORE_EXECUTOR,
    ctmInfrastructureTransition: ethers.constants.AddressZero,
    ctmTransition: CTM_TRANSITION,
    ctmExecutor: CTM_EXECUTOR,
  });
  assert.deepEqual(transitionOnly, [TRANSITION_LEG]);
});

test("a reported object without its executor, or no object at all, is refused", () => {
  assert.throws(
    () => upgradeLegsOf({ coreTransition: CORE_TRANSITION, coreExecutor: ethers.constants.AddressZero }),
    /core leg's object .* without the executor/
  );
  assert.throws(() => upgradeLegsOf({ ctmTransition: CTM_TRANSITION }), /ctmTransition leg's object .* without/);
  assert.throws(
    () => upgradeLegsOf({ coreExecutor: CORE_EXECUTOR, ctmExecutor: CTM_EXECUTOR }),
    /no upgrade object, so the bundle has no leg/
  );
});

test("legs are recovered with their positions; calls around the run are left to the caller", () => {
  const calls = decodeGovernanceCalls(encodeGovernanceCalls([OTHER_CALL, ...ALL_LEGS.map(legCall), OTHER_CALL]));
  const legs = recoverUpgradeLegs(calls, SELECTORS);
  assert.deepEqual(
    legs.map((leg) => [leg.kind, leg.position, leg.executor, leg.object]),
    [
      ["core", 1, CORE_EXECUTOR, CORE_TRANSITION],
      ["ctmInfrastructure", 2, CTM_EXECUTOR, CTM_INFRASTRUCTURE],
      ["ctmTransition", 3, CTM_EXECUTOR, CTM_TRANSITION],
    ]
  );
  assert.deepEqual(assertUpgradeLegs(calls, SELECTORS, ALL_LEGS), legs);
});

test("every subsequence of the legs in canonical order passes", () => {
  for (const subset of [
    [CORE_LEG],
    [TRANSITION_LEG],
    [CORE_LEG, TRANSITION_LEG],
    [INFRASTRUCTURE_LEG, TRANSITION_LEG],
  ]) {
    const calls = decodeGovernanceCalls(encodeGovernanceCalls(subset.map(legCall)));
    assert.equal(assertUpgradeLegs(calls, SELECTORS, subset).length, subset.length);
  }
});

test("swapped legs are refused, naming the canonical order", () => {
  const swapped = decodeGovernanceCalls(encodeGovernanceCalls([legCall(TRANSITION_LEG), legCall(CORE_LEG)]));
  assert.throws(
    () => recoverUpgradeLegs(swapped, SELECTORS),
    /core at \[1\] comes after ctmTransition at \[0\]; the legs must run in the order core -> ctmInfrastructure -> ctmTransition/
  );
  const infraLast = decodeGovernanceCalls(
    encodeGovernanceCalls([legCall(TRANSITION_LEG), legCall(INFRASTRUCTURE_LEG)])
  );
  assert.throws(() => recoverUpgradeLegs(infraLast, SELECTORS), /ctmInfrastructure at \[1\] comes after ctmTransition/);
});

test("a duplicated leg is refused, even with another object", () => {
  const duplicated = decodeGovernanceCalls(
    encodeGovernanceCalls([legCall(CORE_LEG), legCall({ ...CORE_LEG, object: STRANGER })])
  );
  assert.throws(
    () => recoverUpgradeLegs(duplicated, SELECTORS),
    /the core leg appears twice: core at \[0\] and core at \[1\]/
  );
});

test("a call between two legs breaks the run and is refused", () => {
  const split = decodeGovernanceCalls(encodeGovernanceCalls([legCall(CORE_LEG), OTHER_CALL, legCall(TRANSITION_LEG)]));
  assert.throws(
    () => recoverUpgradeLegs(split, SELECTORS),
    /not one contiguous run: 1 other call\(s\) between core at \[0\] and ctmTransition at \[2\]/
  );
});

test("a leg with value, extra calldata or a dirty address word is refused", () => {
  const valued = decodeGovernanceCalls(encodeGovernanceCalls([{ ...legCall(CORE_LEG), value: 1 }]));
  assert.throws(() => recoverUpgradeLegs(valued, SELECTORS), /core leg at \[0\] carries value 1/);
  const extended = decodeGovernanceCalls(
    encodeGovernanceCalls([{ ...legCall(CORE_LEG), data: ethers.utils.hexConcat([legCall(CORE_LEG).data, "0x00"]) }])
  );
  assert.throws(() => recoverUpgradeLegs(extended, SELECTORS), /exactly one address argument/);
  const dirtyWord = ethers.utils.hexConcat([SELECTORS.core, "0x01", ethers.utils.hexZeroPad(CORE_TRANSITION, 31)]);
  const dirty = decodeGovernanceCalls(encodeGovernanceCalls([{ target: CORE_EXECUTOR, data: dirtyWord }]));
  assert.throws(() => recoverUpgradeLegs(dirty, SELECTORS), /exactly one address argument/);
});

test("a missing, unexpected, mis-targeted or substituted leg differs from the reported upgrade", () => {
  const decode = (legs: UpgradeLeg[]) => decodeGovernanceCalls(encodeGovernanceCalls(legs.map(legCall)));
  assert.throws(
    () => assertUpgradeLegs(decode([TRANSITION_LEG]), SELECTORS, [CORE_LEG, TRANSITION_LEG]),
    /missing the core leg/
  );
  assert.throws(
    () => assertUpgradeLegs(decode([CORE_LEG, TRANSITION_LEG]), SELECTORS, [TRANSITION_LEG]),
    /unexpected core at \[0\]/
  );
  assert.throws(
    () => assertUpgradeLegs(decode([{ ...CORE_LEG, executor: STRANGER }]), SELECTORS, [CORE_LEG]),
    new RegExp(`core at \\[0\\] calls ${STRANGER}, expected the executor ${CORE_EXECUTOR}`)
  );
  assert.throws(
    () => assertUpgradeLegs(decode([{ ...TRANSITION_LEG, object: CORE_TRANSITION }]), SELECTORS, [TRANSITION_LEG]),
    new RegExp(`ctmTransition at \\[0\\] applies ${CORE_TRANSITION}, expected ${CTM_TRANSITION}`)
  );
});

test("a registry hop passes with exactly its legs and no external action", () => {
  const legs = assertRegistryHopBundle(merged([CORE_LEG, TRANSITION_LEG].map(legCall)), SELECTORS, [
    CORE_LEG,
    TRANSITION_LEG,
  ]);
  assert.deepEqual(
    legs.map((leg) => leg.kind),
    ["core", "ctmTransition"]
  );
});

test("a registry hop refuses an empty bundle and any call besides its legs", () => {
  assert.throws(
    () => assertRegistryHopBundle(merged([]), SELECTORS, [TRANSITION_LEG]),
    /missing the ctmTransition leg/
  );
  for (const calls of [
    [OTHER_CALL, legCall(TRANSITION_LEG)],
    [legCall(TRANSITION_LEG), OTHER_CALL],
  ]) {
    assert.throws(
      () => assertRegistryHopBundle(merged(calls), SELECTORS, [TRANSITION_LEG]),
      /must carry only its upgrade legs, got also:\n {2}\[\d\] target 0x0000000000000000000000000000000000000099/
    );
  }
});

test("a registry hop refuses any declared external action, admin phase included", () => {
  for (const phase of ["governance", "admin"]) {
    const output = merged([legCall(TRANSITION_LEG)], [{ phase, label: "an undeclared extra", target: address(9) }]);
    assert.throws(
      () => assertRegistryHopBundle(output, SELECTORS, [TRANSITION_LEG]),
      new RegExp(`phase ${phase} \\| an undeclared extra`)
    );
  }
});

run();
