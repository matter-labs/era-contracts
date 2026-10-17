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

// ── Direct upgrade legs ──────────────────────────────────────────────

/**
 * The direct upgrade legs a governance bundle may carry, in the one order it must carry them: the
 * ecosystem's proxies, then the CTM domain's proxies, then the CTM transition (see
 * {protocol-docs/ecosystem-upgrade-coordination.md}).
 */
export const UPGRADE_LEG_KINDS = ["core", "ctmInfrastructure", "ctmTransition"] as const;
export type UpgradeLegKind = (typeof UPGRADE_LEG_KINDS)[number];

/**
 * Each leg's entrypoint selector: `CoreUpgradeExecutor.applyL1Upgrade`,
 * `CTMUpgradeExecutor.applyInfrastructureUpgrade`, `CTMUpgradeExecutor.applyCTMUpgrade`.
 */
export type UpgradeLegSelectors = Record<UpgradeLegKind, string>;

/** One leg: the domain executor called and the object it applies. */
export type UpgradeLeg = { kind: UpgradeLegKind; executor: string; object: string };

/** A leg as recovered from a bundle, with its index in the bundle. */
export type RecoveredUpgradeLeg = UpgradeLeg & { position: number };

const ONE_ADDRESS_ARGUMENT_BYTES = 4 + 32;

function legOrder(kind: UpgradeLegKind): number {
  return UPGRADE_LEG_KINDS.indexOf(kind);
}

/**
 * The legs a prepare reported, in canonical order: one per nonzero object, applied through the
 * executor its domain names. Throws when an object has no executor or when nothing is reported.
 */
export function upgradeLegsOf(reported: {
  coreTransition?: string;
  coreExecutor?: string;
  ctmInfrastructureTransition?: string;
  ctmTransition?: string;
  ctmExecutor?: string;
}): UpgradeLeg[] {
  const isSet = (a?: string): a is string => !!a && a !== ethers.constants.AddressZero;
  const objects: Record<UpgradeLegKind, [string | undefined, string | undefined]> = {
    core: [reported.coreTransition, reported.coreExecutor],
    ctmInfrastructure: [reported.ctmInfrastructureTransition, reported.ctmExecutor],
    ctmTransition: [reported.ctmTransition, reported.ctmExecutor],
  };
  const legs: UpgradeLeg[] = [];
  for (const kind of UPGRADE_LEG_KINDS) {
    const [object, executor] = objects[kind];
    if (!isSet(object)) {
      continue;
    }
    if (!isSet(executor)) {
      throw new Error(`the ${kind} leg's object ${object} is reported without the executor that applies it`);
    }
    legs.push({ kind, executor: ethers.utils.getAddress(executor), object: ethers.utils.getAddress(object) });
  }
  if (legs.length === 0) {
    throw new Error("the prepares report no upgrade object, so the bundle has no leg to carry");
  }
  return legs;
}

function describeLeg(leg: RecoveredUpgradeLeg): string {
  return `${leg.kind} at [${leg.position}]`;
}

/**
 * Every leg call in `calls` (recognized by its selector), checked for the bundle shape governance
 * may sign: each call value-free with exactly one canonically encoded address argument, no kind
 * twice, the kinds in canonical order, and no other call between them. Other calls are left to
 * the caller.
 */
export function recoverUpgradeLegs(calls: GovernanceCall[], selectors: UpgradeLegSelectors): RecoveredUpgradeLeg[] {
  const kindBySelector = new Map<string, UpgradeLegKind>(
    UPGRADE_LEG_KINDS.map((kind) => [selectors[kind].toLowerCase(), kind])
  );
  const legs: RecoveredUpgradeLeg[] = [];
  calls.forEach((call, position) => {
    const kind = kindBySelector.get(call.data.slice(0, 10).toLowerCase());
    if (!kind) {
      return;
    }
    if (!call.value.isZero()) {
      throw new Error(`the ${kind} leg at [${position}] carries value ${call.value.toString()}`);
    }
    const malformed = new Error(`the ${kind} leg at [${position}] does not carry exactly one address argument`);
    if (ethers.utils.hexDataLength(call.data) !== ONE_ADDRESS_ARGUMENT_BYTES) {
      throw malformed;
    }
    // An address word is 12 zero bytes and the address; anything else is not the call governance reviewed.
    const word = ethers.utils.hexDataSlice(call.data, 4);
    if (!ethers.BigNumber.from(ethers.utils.hexDataSlice(word, 0, 12)).isZero()) {
      throw malformed;
    }
    const object = ethers.utils.getAddress(ethers.utils.hexDataSlice(word, 12));
    legs.push({ kind, executor: ethers.utils.getAddress(call.target), object, position });
  });
  for (let i = 1; i < legs.length; i++) {
    const [previous, leg] = [legs[i - 1], legs[i]];
    const earlier = legs.slice(0, i).find((l) => l.kind === leg.kind);
    if (earlier) {
      throw new Error(`the ${leg.kind} leg appears twice: ${describeLeg(earlier)} and ${describeLeg(leg)}`);
    }
    if (legOrder(leg.kind) < legOrder(previous.kind)) {
      throw new Error(
        `${describeLeg(leg)} comes after ${describeLeg(previous)}; ` +
          `the legs must run in the order ${UPGRADE_LEG_KINDS.join(" -> ")}`
      );
    }
    if (leg.position !== previous.position + 1) {
      throw new Error(
        `the legs are not one contiguous run: ${leg.position - previous.position - 1} other call(s) ` +
          `between ${describeLeg(previous)} and ${describeLeg(leg)}`
      );
    }
  }
  return legs;
}

/**
 * Throws unless the legs {@link recoverUpgradeLegs} finds in `calls` are exactly `expected` — the
 * same kinds, each on the expected executor naming the expected object. Returns the recovered legs.
 */
export function assertUpgradeLegs(
  calls: GovernanceCall[],
  selectors: UpgradeLegSelectors,
  expected: UpgradeLeg[]
): RecoveredUpgradeLeg[] {
  const legs = recoverUpgradeLegs(calls, selectors);
  const problems: string[] = [];
  for (const want of expected) {
    const got = legs.find((leg) => leg.kind === want.kind);
    if (!got) {
      problems.push(`  missing the ${want.kind} leg (${want.executor} applying ${want.object})`);
      continue;
    }
    if (got.executor.toLowerCase() !== want.executor.toLowerCase()) {
      problems.push(`  ${describeLeg(got)} calls ${got.executor}, expected the executor ${want.executor}`);
    }
    if (got.object.toLowerCase() !== want.object.toLowerCase()) {
      problems.push(`  ${describeLeg(got)} applies ${got.object}, expected ${want.object}`);
    }
  }
  for (const got of legs) {
    if (!expected.some((want) => want.kind === got.kind)) {
      problems.push(`  unexpected ${describeLeg(got)} (${got.executor} applying ${got.object})`);
    }
  }
  if (problems.length !== 0) {
    throw new Error(`the bundle's upgrade legs differ from the reported upgrade:\n${problems.join("\n")}`);
  }
  return legs;
}

/**
 * A recurring registry hop's merged output: the bundle is exactly the reported upgrade's legs, one
 * contiguous run in canonical order with no other call, and the prepares declared no external
 * action of any phase (after the bootstrap, governance holds both domains through the executors).
 */
export function assertRegistryHopBundle(
  merged: MergedGovernanceOutput,
  selectors: UpgradeLegSelectors,
  expected: UpgradeLeg[]
): RecoveredUpgradeLeg[] {
  const calls = governanceCallsOf(merged);
  const legs = assertUpgradeLegs(calls, selectors, expected);
  const others = calls
    .map((call, position) => ({ call, position }))
    .filter(({ position }) => !legs.some((leg) => leg.position === position));
  if (others.length !== 0) {
    const lines = others.map(({ call, position }) => `  [${position}] ${describeCall(call)}`);
    throw new Error(`a registry hop's bundle must carry only its upgrade legs, got also:\n${lines.join("\n")}`);
  }
  const externalActions = merged.external_actions ?? [];
  if (externalActions.length !== 0) {
    const lines = externalActions.map((a) => `  phase ${a.phase} | ${a.label} | target ${a.target ?? "?"}`);
    throw new Error(`a registry hop's prepares must declare no external actions, got:\n${lines.join("\n")}`);
  }
  return legs;
}
