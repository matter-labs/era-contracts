/**
 * The governance bundle of a merged upgrade prepare (`[governance_calls] calls`,
 * `abi.encode(Call[])`) and the shape checks the upgrade runners hold it to. Pure functions over the
 * parsed TOML, so the unit suite covers them without a chain.
 */

import { ethers } from "ethers";

/** One `Call` of a governance bundle (`contracts/governance/Common.sol`). */
export type GovernanceCall = { target: string; value: ethers.BigNumber; data: string };

/** A call a runner expects in a bundle, named for the failure message. */
export type ExpectedCall = { label: string; target: string; value?: ethers.BigNumberish; data: string };

/** One `[[external_actions]]` entry of a prepare output (`ExternalActionsLib.serialize`). */
export type ExternalActionEntry = {
  phase: string;
  label: string;
  authority?: string;
  target?: string;
  value?: string;
  data?: string;
};

/** The parts of a merged `ecosystem.toml` the bundle checks read. */
export type MergedGovernanceOutput = {
  governance_calls?: Record<string, unknown>;
  external_actions?: ExternalActionEntry[];
};

const CALL_ARRAY_TYPE = "tuple(address target,uint256 value,bytes data)[]";

/** `abi.decode(Call[])` of a bundle's hex; `0x` and the empty string decode to no calls. */
export function decodeGovernanceCalls(hex: string): GovernanceCall[] {
  if (hex === "0x" || hex === "") {
    return [];
  }
  const [calls] = ethers.utils.defaultAbiCoder.decode([CALL_ARRAY_TYPE], hex);
  return calls.map((c: GovernanceCall) => ({ target: c.target, value: c.value, data: c.data }));
}

/** `abi.encode(Call[])`. */
export function encodeGovernanceCalls(
  calls: Array<{ target: string; value?: ethers.BigNumberish; data: string }>
): string {
  return ethers.utils.defaultAbiCoder.encode(
    [CALL_ARRAY_TYPE],
    [calls.map((c) => ({ target: c.target, value: c.value ?? 0, data: c.data }))]
  );
}

/**
 * The bundle of a merged prepare output. Refuses a `[governance_calls]` table with any key besides
 * `calls`, so an output in the retired per-stage format fails here instead of reading as empty.
 */
export function governanceCallsOf(merged: MergedGovernanceOutput): GovernanceCall[] {
  const table = merged.governance_calls;
  if (!table) {
    throw new Error("the merged prepare output has no [governance_calls] table");
  }
  const staleKeys = Object.keys(table).filter((key) => key !== "calls");
  if (staleKeys.length !== 0) {
    throw new Error(`[governance_calls] carries keys other than \`calls\`: ${staleKeys.join(", ")}`);
  }
  if (typeof table.calls !== "string") {
    throw new Error("[governance_calls] calls is missing from the merged prepare output");
  }
  return decodeGovernanceCalls(table.calls);
}

function describeCall(call: { target: string; value?: ethers.BigNumberish; data: string }): string {
  return `target ${call.target}, value ${ethers.BigNumber.from(call.value ?? 0).toString()}, selector ${call.data.slice(0, 10)}`;
}

/** Throws unless `actual` is exactly `expected`, call for call (target, value, calldata), in order. */
export function assertBundleIs(actual: GovernanceCall[], expected: ExpectedCall[], what: string): void {
  const problems: string[] = [];
  if (actual.length !== expected.length) {
    problems.push(`  ${actual.length} call(s), expected ${expected.length}`);
  }
  for (let i = 0; i < Math.max(actual.length, expected.length); i++) {
    const a = actual[i];
    const e = expected[i];
    if (!a) {
      problems.push(`  [${i}] missing: ${e.label} (${describeCall(e)})`);
      continue;
    }
    if (!e) {
      problems.push(`  [${i}] unexpected: ${describeCall(a)}`);
      continue;
    }
    const same =
      a.target.toLowerCase() === e.target.toLowerCase() &&
      a.value.eq(ethers.BigNumber.from(e.value ?? 0)) &&
      a.data.toLowerCase() === e.data.toLowerCase();
    if (!same) {
      problems.push(`  [${i}] expected ${e.label} (${describeCall(e)}), got ${describeCall(a)}`);
    }
  }
  if (problems.length !== 0) {
    throw new Error(`${what} differs from the expected bundle:\n${problems.join("\n")}`);
  }
}

/**
 * A recurring registry hop's merged output: the bundle is exactly the one derived
 * `EcosystemUpgradeExecutor.execute(operation)` call, and the prepares declared no external action
 * of any phase (after the bootstrap, governance holds the whole CTM domain through the executors).
 */
export function assertRegistryHopBundle(merged: MergedGovernanceOutput, execute: ExpectedCall): void {
  assertBundleIs(governanceCallsOf(merged), [execute], "the registry hop's governance bundle");
  const externalActions = merged.external_actions ?? [];
  if (externalActions.length !== 0) {
    const lines = externalActions.map((a) => `  phase ${a.phase} | ${a.label} | target ${a.target ?? "?"}`);
    throw new Error(`a registry hop's prepares must declare no external actions, got:\n${lines.join("\n")}`);
  }
}
