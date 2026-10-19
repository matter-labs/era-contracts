import * as assert from "assert/strict";
import { ethers } from "ethers";
import { ETHEREUM_L1_TX_GAS_LIMIT } from "../../src/core/const";
import { checkL1TransactionGas } from "../../src/helpers/l1-transaction-gas";
import type { L1TransactionGasContext } from "../../src/helpers/l1-transaction-gas";
import { createSuite } from "./harness";

const { test, run } = createSuite("l1-transaction-gas");

const context: L1TransactionGasContext = {
  phase: "prepare",
  bundle: "deployer.json",
  index: 3,
  target: "0x0000000000000000000000000000000000000001",
};

function receipt(gasUsed: number, status = 1) {
  return { status, transactionHash: "0x1234", gasUsed: ethers.BigNumber.from(gasUsed) };
}

test("records gas and transaction provenance at the Ethereum L1 boundary", () => {
  assert.equal(ETHEREUM_L1_TX_GAS_LIMIT, 16_777_216);
  assert.deepEqual(checkL1TransactionGas(receipt(ETHEREUM_L1_TX_GAS_LIMIT), ETHEREUM_L1_TX_GAS_LIMIT, context), {
    ...context,
    transactionHash: "0x1234",
    gasLimit: ETHEREUM_L1_TX_GAS_LIMIT,
    gasUsed: ETHEREUM_L1_TX_GAS_LIMIT,
  });
});

test("rejects an invalid declared gas limit even when execution uses little gas", () => {
  assert.throws(
    () => checkL1TransactionGas(receipt(21_000), ETHEREUM_L1_TX_GAS_LIMIT + 1, context),
    /prepare deployer\.json tx 3 .*gas limit 16777217 exceeds Ethereum L1 cap 16777216/
  );
});

test("rejects usage over the budget and names the failing governance transaction", () => {
  assert.throws(
    () =>
      checkL1TransactionGas(receipt(ETHEREUM_L1_TX_GAS_LIMIT + 1), ETHEREUM_L1_TX_GAS_LIMIT, {
        ...context,
        phase: "governance",
      }),
    /governance deployer\.json tx 3 .*gas used 16777217 exceeds Ethereum L1 cap 16777216/
  );
});

test("a reverted chain upgrade cannot produce a successful budget record", () => {
  assert.throws(
    () =>
      checkL1TransactionGas(receipt(21_000, 0), ETHEREUM_L1_TX_GAS_LIMIT, {
        ...context,
        phase: "chain-upgrade",
      }),
    /chain-upgrade deployer\.json tx 3 .*transaction 0x1234 did not succeed/
  );
});

run();
