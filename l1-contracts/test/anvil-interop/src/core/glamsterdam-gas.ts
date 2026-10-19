import { ethers } from "ethers";
import {
  CALL_GAS_RETAINED_DIVISOR,
  CALLDATA_NONZERO_BYTE_GAS,
  CALLDATA_ZERO_BYTE_GAS,
  ETHEREUM_L1_TX_GAS_LIMIT,
  EVM_WORD_BYTES,
  GLAMSTERDAM_CALLDATA_FLOOR_GAS_PER_BYTE,
  GLAMSTERDAM_COST_PER_STATE_BYTE,
  GLAMSTERDAM_NEW_ACCOUNT_BYTES,
  GLAMSTERDAM_STORAGE_SLOT_BYTES,
  GLAMSTERDAM_TX_BASE_GAS,
  GLAMSTERDAM_TX_COLD_RECIPIENT_GAS,
  GLAMSTERDAM_TX_CREATE_GAS,
  GLAMSTERDAM_TX_VALUE_GAS,
  INITCODE_WORD_GAS,
  MAX_REFUND_QUOTIENT,
} from "./const";

/**
 * The L1 gas rules the harness runs under, from `L1_GAS_RULES`. The default, "osaka", sends and asserts every L1
 * tx within EIP-7825's cap. "amsterdam" starts the L1 from `ANVIL_AMSTERDAM_BIN` with Glamsterdam's gas schedule
 * (src/daemons/amsterdam-l1.ts): there EIP-8037 state gas lets `tx.gas` exceed the cap, so txs declare their
 * estimate and each recorded tx is held to the cap on its execution gas instead.
 */
export const L1_GAS_RULES: "osaka" | "amsterdam" = readL1GasRules();

function readL1GasRules(): "osaka" | "amsterdam" {
  const rules = process.env.L1_GAS_RULES?.trim() || "osaka";
  if (rules !== "osaka" && rules !== "amsterdam") {
    throw new Error(`L1_GAS_RULES must be "osaka" or "amsterdam", got "${rules}"`);
  }
  return rules;
}

/** One account of a `prestateTracer` result in diff mode. */
export type PrestateAccount = {
  balance?: string;
  nonce?: number | string;
  code?: string;
  storage?: Record<string, string>;
};

export type PrestateDiff = { pre?: Record<string, PrestateAccount>; post?: Record<string, PrestateAccount> };

/** One frame of a `callTracer` result. */
export type CallFrame = { calls?: CallFrame[] };

/** What a transaction adds to the state, the quantities EIP-8037 prices as state gas. */
export type StateGrowth = { newAccounts: number; newCodeBytes: number; newSlots: number };

export type GlamsterdamGas = StateGrowth & {
  blockGasLimit: number;
  refundCounter: number;
  preRefund: number;
  stateGas: number;
  /** Derived from `gasUsed`, so only an upper bound when `floorBinding`. */
  execGas: number;
  intrinsic: number;
  floor: number;
  /** `gasUsed` is EIP-7976's calldata floor, not the gas the transaction ran on. */
  floorBinding: boolean;
  /** How many call or create levels the transaction nests below its top frame. */
  callDepth: number;
};

function quantity(value: string | number | undefined): bigint {
  return value === undefined ? 0n : BigInt(value);
}

/**
 * Accounts, runtime bytes and storage slots a transaction created, read from its prestate diff. The block's
 * miner is skipped: its fee credit is not the transaction's state.
 */
export function stateGrowthFromPrestateDiff(diff: PrestateDiff, miner: string): StateGrowth {
  const pre = new Map(Object.entries(diff.pre ?? {}).map(([address, account]) => [address.toLowerCase(), account]));
  const growth: StateGrowth = { newAccounts: 0, newCodeBytes: 0, newSlots: 0 };
  for (const [address, post] of Object.entries(diff.post ?? {})) {
    if (address.toLowerCase() === miner.toLowerCase()) {
      continue;
    }
    const before = pre.get(address.toLowerCase()) ?? {};
    const codeBefore = before.code || "0x";
    if (quantity(before.balance) === 0n && quantity(before.nonce) === 0n && codeBefore === "0x") {
      growth.newAccounts++;
    }
    const codeAfter = post.code || "0x";
    if (codeAfter !== "0x" && codeBefore === "0x") {
      growth.newCodeBytes += Math.floor((codeAfter.length - 2) / 2);
    }
    const storageBefore = new Map(
      Object.entries(before.storage ?? {}).map(([slot, value]) => [slot.toLowerCase(), value])
    );
    for (const [slot, value] of Object.entries(post.storage ?? {})) {
      if (quantity(value) !== 0n && quantity(storageBefore.get(slot.toLowerCase())) === 0n) {
        growth.newSlots++;
      }
    }
  }
  return growth;
}

export function glamsterdamStateGas(growth: StateGrowth): number {
  return (
    GLAMSTERDAM_COST_PER_STATE_BYTE *
    (GLAMSTERDAM_NEW_ACCOUNT_BYTES * growth.newAccounts +
      growth.newCodeBytes +
      GLAMSTERDAM_STORAGE_SLOT_BYTES * growth.newSlots)
  );
}

/** EIP-2780 intrinsic gas and EIP-7976 calldata floor of a transaction. */
export function glamsterdamIntrinsicGas(tx: {
  from: string;
  to?: string | null;
  value: ethers.BigNumberish;
  data: string;
}): { intrinsic: number; floor: number } {
  const data = ethers.utils.arrayify(tx.data);
  const zeros = data.filter((byte) => byte === 0).length;
  const to = tx.to ? tx.to.toLowerCase() : null;
  const toOther = to !== null && to !== tx.from.toLowerCase();
  let base = GLAMSTERDAM_TX_BASE_GAS;
  if (toOther) {
    base += GLAMSTERDAM_TX_COLD_RECIPIENT_GAS;
  } else if (to === null) {
    base += GLAMSTERDAM_TX_CREATE_GAS;
  }
  if (toOther && ethers.BigNumber.from(tx.value).gt(0)) {
    base += GLAMSTERDAM_TX_VALUE_GAS;
  }
  const initcodeWords = to === null ? Math.ceil(data.length / EVM_WORD_BYTES) : 0;
  return {
    intrinsic:
      base +
      CALLDATA_ZERO_BYTE_GAS * zeros +
      CALLDATA_NONZERO_BYTE_GAS * (data.length - zeros) +
      INITCODE_WORD_GAS * initcodeWords,
    floor: base + GLAMSTERDAM_CALLDATA_FLOOR_GAS_PER_BYTE * data.length,
  };
}

/** Call or create levels below the top frame of a `callTracer` result. */
export function maxCallDepth(frame: CallFrame): number {
  let depth = 0;
  for (const call of frame.calls ?? []) {
    depth = Math.max(depth, 1 + maxCallDepth(call));
  }
  return depth;
}

/**
 * The execution gas Glamsterdam leaves a frame `depth` calls deep, before the frames above it spend any: EIP-8037
 * caps the top frame's `gas_left` at 2^24 minus the intrinsic gas, and each call level keeps back a 64th of what
 * reaches it. The state gas reservoir passes to sub-calls in full, so it does not count here.
 */
export function executionBudgetAtDepth(intrinsic: number, depth: number): number {
  let budget = ETHEREUM_L1_TX_GAS_LIMIT - intrinsic;
  for (let level = 0; level < depth; level++) {
    budget -= Math.floor(budget / CALL_GAS_RETAINED_DIVISOR);
  }
  return budget;
}

/** Gas a transaction used before its refund, from its receipt's `gasUsed` and its final refund counter. */
export function preRefundGas(gasUsed: number, refundCounter: number): number {
  if ((MAX_REFUND_QUOTIENT - 1) * refundCounter <= gasUsed) {
    return gasUsed + refundCounter;
  }
  return Math.ceil((gasUsed * MAX_REFUND_QUOTIENT) / (MAX_REFUND_QUOTIENT - 1));
}

/**
 * A mined transaction's gas split under Glamsterdam. Anvil does not split the reservoir, so the execution gas is
 * derived: the gas used before refund minus the state gas of what the transaction created.
 */
export function glamsterdamGas(params: {
  diff: PrestateDiff;
  miner: string;
  blockGasLimit: number;
  gasUsed: number;
  refundCounter: number;
  callDepth: number;
  tx: { from: string; to?: string | null; value: ethers.BigNumberish; data: string };
}): GlamsterdamGas {
  const growth = stateGrowthFromPrestateDiff(params.diff, params.miner);
  const stateGas = glamsterdamStateGas(growth);
  const preRefund = preRefundGas(params.gasUsed, params.refundCounter);
  const { intrinsic, floor } = glamsterdamIntrinsicGas(params.tx);
  return {
    ...growth,
    blockGasLimit: params.blockGasLimit,
    refundCounter: params.refundCounter,
    preRefund,
    stateGas,
    execGas: preRefund - stateGas,
    intrinsic,
    floor,
    floorBinding: params.gasUsed === floor,
    callDepth: params.callDepth,
  };
}

/**
 * The ways a transaction breaks Glamsterdam's limits; empty when it fits. Anvil runs a single gas pool, so its
 * 63/64 rule applies to the whole `tx.gas` and a transaction can succeed there with more gas in a sub-call than
 * Glamsterdam gives it. The execution gas past the intrinsic is therefore held to `executionBudgetAtDepth` at the
 * transaction's deepest call level: if all of it fits there, every frame gets what it used. Sufficient, not
 * necessary.
 */
export function glamsterdamGasViolations(gas: GlamsterdamGas): string[] {
  const violations: string[] = [];
  const runtimeExecGas = gas.execGas - gas.intrinsic;
  const budget = executionBudgetAtDepth(gas.intrinsic, gas.callDepth);
  if (runtimeExecGas > budget) {
    const bound = gas.floorBinding ? " (an upper bound: the calldata floor binds)" : "";
    violations.push(
      `execution gas past the intrinsic ${runtimeExecGas}${bound} exceeds ${budget}, ` +
        `what Glamsterdam guarantees a frame ${gas.callDepth} calls deep`
    );
  }
  const intrinsicOrFloor = Math.max(gas.intrinsic, gas.floor);
  if (intrinsicOrFloor > ETHEREUM_L1_TX_GAS_LIMIT) {
    violations.push(`intrinsic/floor gas ${intrinsicOrFloor} exceeds the ${ETHEREUM_L1_TX_GAS_LIMIT} transaction cap`);
  }
  return violations;
}
