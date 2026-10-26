import * as assert from "assert/strict";
import { AMSTERDAM_L1_BLOCK_GAS_LIMIT, ETHEREUM_L1_TX_GAS_LIMIT } from "../../src/core/const";
import type { GlamsterdamGas, PrestateDiff } from "../../src/core/glamsterdam-gas";
import {
  executionBudgetAtDepth,
  glamsterdamGas,
  glamsterdamGasViolations,
  glamsterdamIntrinsicGas,
  glamsterdamStateGas,
  maxCallDepth,
  preRefundGas,
  stateGrowthFromPrestateDiff,
} from "../../src/core/glamsterdam-gas";
import { toAmsterdamStateDump } from "../../src/daemons/amsterdam-l1";
import { createSuite } from "./harness";

const { test, run } = createSuite("glamsterdam-gas");

const SENDER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const TARGET = "0x9534db27bc15b8faf501f4c19f4cea77061d52d5";
const MINER = "0x0000000000000000000000000000000000000000";

function bytes(zeros: number, nonZeros: number): string {
  return "0x" + "00".repeat(zeros) + "ab".repeat(nonZeros);
}

test("state gas prices a new account at 120 bytes, a new slot at 64 and runtime per byte", () => {
  assert.equal(glamsterdamStateGas({ newAccounts: 1, newCodeBytes: 0, newSlots: 0 }), 183_600);
  assert.equal(glamsterdamStateGas({ newAccounts: 0, newCodeBytes: 0, newSlots: 1 }), 97_920);
  assert.equal(glamsterdamStateGas({ newAccounts: 1, newCodeBytes: 1000, newSlots: 2 }), 1530 * (120 + 1000 + 128));
});

test("intrinsic gas and calldata floor of a call (the reference analyzer's prepare tx 1)", () => {
  // 36 bytes, 12 of them zero, to another account without value: 15,432 intrinsic and a 17,304 floor.
  assert.deepEqual(glamsterdamIntrinsicGas({ from: SENDER, to: TARGET, value: 0, data: bytes(12, 24) }), {
    intrinsic: 15_432,
    floor: 17_304,
  });
});

test("a value-less transfer costs 15,000 and a value transfer adds 6,000", () => {
  assert.deepEqual(glamsterdamIntrinsicGas({ from: SENDER, to: TARGET, value: 0, data: "0x" }), {
    intrinsic: 15_000,
    floor: 15_000,
  });
  assert.equal(glamsterdamIntrinsicGas({ from: SENDER, to: TARGET, value: 1, data: "0x" }).intrinsic, 21_000);
});

test("a transaction to its own sender pays neither the cold recipient nor the value", () => {
  assert.equal(
    glamsterdamIntrinsicGas({ from: SENDER, to: SENDER.toLowerCase(), value: 1, data: "0x" }).intrinsic,
    12_000
  );
});

test("a contract creation pays the create cost and the initcode words", () => {
  // 33 bytes = two 32-byte words.
  assert.deepEqual(glamsterdamIntrinsicGas({ from: SENDER, to: null, value: 0, data: bytes(1, 32) }), {
    intrinsic: 12_000 + 12_000 + 4 + 16 * 32 + 2 * 2,
    floor: 12_000 + 12_000 + 64 * 33,
  });
});

test("state growth counts created accounts, new runtime and newly set slots only", () => {
  const diff: PrestateDiff = {
    pre: {
      // An existing contract: one slot already set.
      [TARGET.toUpperCase().replace("0X", "0x")]: {
        balance: "0x0",
        nonce: 1,
        code: "0x6000",
        storage: { "0x01": "0x0000000000000000000000000000000000000000000000000000000000000001" },
      },
      // An existing EOA: only its balance moves.
      [SENDER]: { balance: "0x56bc75e2d63100000", nonce: 3 },
    },
    post: {
      [TARGET]: {
        storage: {
          "0x01": "0x0000000000000000000000000000000000000000000000000000000000000002",
          "0x02": "0x0000000000000000000000000000000000000000000000000000000000000005",
        },
      },
      [SENDER]: { balance: "0x56bc75e2d63000000", nonce: 4 },
      // A contract created by this transaction, with 3 bytes of runtime and one slot set.
      "0x00000000000000000000000000000000000000c1": {
        nonce: 1,
        code: "0x600160",
        storage: { "0x00": "0x0000000000000000000000000000000000000000000000000000000000000007" },
      },
      // The fee recipient is never the transaction's state.
      [MINER]: { balance: "0x1" },
    },
  };
  assert.deepEqual(stateGrowthFromPrestateDiff(diff, MINER), { newAccounts: 1, newCodeBytes: 3, newSlots: 2 });
});

test("an account that only had a nonce existed, and a slot cleared to zero is not new", () => {
  const diff: PrestateDiff = {
    pre: { [TARGET]: { nonce: "0x1", storage: { "0x03": "0x01" } } },
    post: { [TARGET]: { balance: "0x5", storage: { "0x03": "0x00" } } },
  };
  assert.deepEqual(stateGrowthFromPrestateDiff(diff, MINER), { newAccounts: 0, newCodeBytes: 0, newSlots: 0 });
});

test("the refund is added back up to EIP-3529's fifth of the pre-refund gas", () => {
  assert.equal(preRefundGas(100_000, 20_000), 120_000);
  assert.equal(preRefundGas(100_000, 30_000), 125_000);
  assert.equal(preRefundGas(100_000, 0), 100_000);
});

test("execution gas is the pre-refund gas minus the state gas (the reference analyzer's governance tx 1)", () => {
  const gas = glamsterdamGas({
    diff: { pre: { [TARGET]: { nonce: 1, code: "0x00" } }, post: { [TARGET]: { storage: { "0x09": "0x01" } } } },
    miner: MINER,
    blockGasLimit: AMSTERDAM_L1_BLOCK_GAS_LIMIT,
    gasUsed: 166_769,
    refundCounter: 0,
    callDepth: 2,
    tx: { from: SENDER, to: TARGET, value: 0, data: bytes(0, 4) },
  });
  assert.deepEqual(
    {
      stateGas: gas.stateGas,
      execGas: gas.execGas,
      preRefund: gas.preRefund,
      newSlots: gas.newSlots,
      floorBinding: gas.floorBinding,
      callDepth: gas.callDepth,
    },
    { stateGas: 97_920, execGas: 68_849, preRefund: 166_769, newSlots: 1, floorBinding: false, callDepth: 2 }
  );
});

test("a receipt that reports the calldata floor is marked floor-binding", () => {
  // 116,650 bytes: the floor 15,000 + 64 * 116,650 = 7,480,600 binds over a cheaper execution.
  const data = bytes(10_000, 106_650);
  const { floor } = glamsterdamIntrinsicGas({ from: SENDER, to: TARGET, value: 0, data });
  const gas = glamsterdamGas({
    diff: {},
    miner: MINER,
    blockGasLimit: AMSTERDAM_L1_BLOCK_GAS_LIMIT,
    gasUsed: floor,
    refundCounter: 0,
    callDepth: 1,
    tx: { from: SENDER, to: TARGET, value: 0, data },
  });
  assert.equal(gas.floorBinding, true);
  assert.equal(gas.execGas, floor);
});

test("call depth counts the deepest nesting of calls and creates below the top frame", () => {
  assert.equal(maxCallDepth({}), 0);
  assert.equal(maxCallDepth({ calls: [] }), 0);
  assert.equal(maxCallDepth({ calls: [{}, { calls: [{ calls: [{}] }] }, { calls: [{}] }] }), 3);
});

test("the execution budget is 2^24 less the intrinsic gas, less a 64th per call level", () => {
  assert.equal(executionBudgetAtDepth(15_000, 0), ETHEREUM_L1_TX_GAS_LIMIT - 15_000);
  // 16,762,216 keeps back floor(16,762,216 / 64) = 261,909.
  assert.equal(executionBudgetAtDepth(15_000, 1), 16_500_307);
  assert.equal(executionBudgetAtDepth(15_000, 2), 16_500_307 - Math.floor(16_500_307 / 64));
});

function gasRecord(overrides: Partial<GlamsterdamGas>): GlamsterdamGas {
  return {
    newAccounts: 0,
    newCodeBytes: 0,
    newSlots: 0,
    blockGasLimit: AMSTERDAM_L1_BLOCK_GAS_LIMIT,
    refundCounter: 0,
    preRefund: 0,
    stateGas: 0,
    execGas: 0,
    intrinsic: 15_000,
    floor: 15_000,
    floorBinding: false,
    callDepth: 0,
    ...overrides,
  };
}

test("a deploy whose tx.gas exceeds 2^24 only through state gas fits Glamsterdam", () => {
  const gas = gasRecord({ stateGas: 32_908_770, execGas: 3_460_782, preRefund: 36_369_552, callDepth: 1 });
  assert.deepEqual(glamsterdamGasViolations(gas), []);
});

test("execution gas over 2^24 fails", () => {
  assert.deepEqual(glamsterdamGasViolations(gasRecord({ execGas: ETHEREUM_L1_TX_GAS_LIMIT + 1 })), [
    "execution gas past the intrinsic 16762217 exceeds 16762216, what Glamsterdam guarantees a frame 0 calls deep",
  ]);
});

test("execution gas under 2^24 that a sub-call only got through anvil's single gas pool fails", () => {
  // Measured on the pinned nightly: a parent forwarding all gas to a child that burns ~16.6M. Its estimate,
  // 16,881,527, succeeds there using 16,618,051, but the same call reverts with tx.gas = 2^24, all Glamsterdam's
  // gas_left can ever be.
  const gas = gasRecord({ execGas: 16_618_051, preRefund: 16_618_051 });
  assert.deepEqual(glamsterdamGasViolations(gas), []);
  assert.deepEqual(glamsterdamGasViolations({ ...gas, callDepth: 1 }), [
    "execution gas past the intrinsic 16603051 exceeds 16500307, what Glamsterdam guarantees a frame 1 calls deep",
  ]);
});

test("a floor-binding transaction's execution gas is reported as an upper bound", () => {
  const gas = gasRecord({ execGas: ETHEREUM_L1_TX_GAS_LIMIT, floor: 16_000_000, floorBinding: true, callDepth: 1 });
  assert.deepEqual(glamsterdamGasViolations(gas), [
    "execution gas past the intrinsic 16762216 (an upper bound: the calldata floor binds) exceeds 16500307, " +
      "what Glamsterdam guarantees a frame 1 calls deep",
  ]);
});

test("intrinsic or floor gas over 2^24 fails", () => {
  const violations = glamsterdamGasViolations(gasRecord({ floor: ETHEREUM_L1_TX_GAS_LIMIT + 64 }));
  assert.deepEqual(violations, [
    `intrinsic/floor gas ${ETHEREUM_L1_TX_GAS_LIMIT + 64} exceeds the ${ETHEREUM_L1_TX_GAS_LIMIT} transaction cap`,
  ]);
});

test("the Amsterdam state dump drops the block history and pins the block gas limit and clock", () => {
  const dump = {
    block: { number: "0x11f", timestamp: "0x120", gas_limit: 100_000_000 },
    accounts: { [SENDER]: { nonce: 1 } },
    best_block_number: 287,
    blocks: [{ header: {} }],
    transactions: [],
  };
  const timestamp = 1_700_000_000;
  assert.deepEqual(toAmsterdamStateDump(dump, timestamp), {
    block: { number: "0x11f", timestamp: "0x6553f100", gas_limit: AMSTERDAM_L1_BLOCK_GAS_LIMIT },
    accounts: { [SENDER]: { nonce: 1 } },
    best_block_number: 287,
  });
  // The committed fixture's decompressed copy is never rewritten in place.
  assert.equal(dump.block.gas_limit, 100_000_000);
  assert.equal(dump.block.timestamp, "0x120");
  assert.equal(dump.blocks.length, 1);
  assert.deepEqual(toAmsterdamStateDump({ accounts: {} }, timestamp), { accounts: {} });
});

run();
