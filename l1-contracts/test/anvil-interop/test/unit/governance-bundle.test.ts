/**
 * Unit tests for the governance-bundle checks the upgrade runners apply to a merged prepare output
 * (`src/helpers/governance-bundle.ts`): reading the one `[governance_calls] calls` bundle, exact
 * call-for-call comparison, and the recurring registry hop's single `execute(operation)` shape.
 *
 * The helpers compare targets and calldata bytes and never decode a function, so the calldata here
 * is opaque bytes standing in for the encoded calls.
 *
 * Run with: yarn test:unit governance-bundle
 */

import * as assert from "assert/strict";
import { ethers } from "ethers";
import type { ExpectedCall, MergedGovernanceOutput } from "../../src/helpers/governance-bundle";
import {
  assertBundleIs,
  assertRegistryHopBundle,
  decodeGovernanceCalls,
  encodeGovernanceCalls,
  governanceCallsOf,
} from "../../src/helpers/governance-bundle";
import { createSuite } from "./harness";

const { test, run } = createSuite("governance-bundle");

const address = (n: number) => ethers.utils.getAddress(ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 20));

const COORDINATOR = address(0xc0);
const OPERATION = address(0x0b);
// Stand-ins for encoded calldata: a 4-byte tag followed by the argument word.
const EXECUTE_DATA = ethers.utils.hexConcat(["0x11111111", ethers.utils.hexZeroPad(OPERATION, 32)]);
const OTHER_DATA = ethers.utils.hexConcat(["0x22222222", ethers.utils.hexZeroPad(OPERATION, 32)]);

const EXECUTE: ExpectedCall = { label: "coordinator.execute(operation)", target: COORDINATOR, data: EXECUTE_DATA };

function merged(
  calls: Array<{ target: string; value?: number; data: string }>,
  externalActions: MergedGovernanceOutput["external_actions"] = []
): MergedGovernanceOutput {
  return { governance_calls: { calls: encodeGovernanceCalls(calls) }, external_actions: externalActions };
}

test("a bundle round-trips through abi.encode(Call[]); an empty bundle decodes to no calls", () => {
  const calls = decodeGovernanceCalls(
    encodeGovernanceCalls([
      { target: COORDINATOR, data: EXECUTE_DATA },
      { target: OPERATION, value: 7, data: "0x" },
    ])
  );
  assert.equal(calls.length, 2);
  assert.equal(calls[0].target, COORDINATOR);
  assert.equal(calls[0].data, EXECUTE_DATA.toLowerCase());
  assert.ok(calls[1].value.eq(7));
  assert.deepEqual(decodeGovernanceCalls("0x"), []);
  assert.deepEqual(decodeGovernanceCalls(encodeGovernanceCalls([])), []);
});

test("the bundle is read from `calls`; the per-stage keys of the old format are refused", () => {
  assert.equal(governanceCallsOf(merged([{ target: COORDINATOR, data: EXECUTE_DATA }])).length, 1);
  const staged = { governance_calls: { stage0_calls: "0x", stage1_calls: "0x", stage2_calls: "0x" } };
  assert.throws(() => governanceCallsOf(staged), /keys other than `calls`: stage0_calls, stage1_calls, stage2_calls/);
  assert.throws(() => governanceCallsOf({}), /no \[governance_calls\] table/);
  assert.throws(() => governanceCallsOf({ governance_calls: {} }), /calls is missing/);
});

test("an identical bundle passes, with addresses compared case-insensitively", () => {
  const calls = governanceCallsOf(merged([{ target: COORDINATOR, data: EXECUTE_DATA }]));
  assertBundleIs(calls, [{ ...EXECUTE, target: COORDINATOR.toLowerCase() }], "bundle");
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

test("a registry hop passes with exactly execute(operation) on the coordinator and no external action", () => {
  assertRegistryHopBundle(merged([{ target: COORDINATOR, data: EXECUTE_DATA }]), EXECUTE);
});

test("a registry hop refuses an empty bundle, a second call, another target or other calldata", () => {
  assert.throws(() => assertRegistryHopBundle(merged([]), EXECUTE), /0 call\(s\), expected 1/);
  assert.throws(
    () =>
      assertRegistryHopBundle(
        merged([
          { target: COORDINATOR, data: EXECUTE_DATA },
          { target: COORDINATOR, data: OTHER_DATA },
        ]),
        EXECUTE
      ),
    /2 call\(s\), expected 1/
  );
  assert.throws(
    () => assertRegistryHopBundle(merged([{ target: OPERATION, data: EXECUTE_DATA }]), EXECUTE),
    /\[0\] expected coordinator\.execute\(operation\)/
  );
  assert.throws(
    () => assertRegistryHopBundle(merged([{ target: COORDINATOR, data: OTHER_DATA }]), EXECUTE),
    /\[0\] expected coordinator\.execute\(operation\)/
  );
});

test("a registry hop refuses any declared external action, admin phase included", () => {
  for (const phase of ["governance", "admin"]) {
    const output = merged(
      [{ target: COORDINATOR, data: EXECUTE_DATA }],
      [{ phase, label: "an undeclared extra", target: address(9) }]
    );
    assert.throws(() => assertRegistryHopBundle(output, EXECUTE), new RegExp(`phase ${phase} \\| an undeclared extra`));
  }
});

run();
