/**
 * Unit tests for waiting on impersonated Anvil relay transactions.
 */

import * as assert from "assert/strict";
import type { providers } from "ethers";
import { waitForAnvilTransaction } from "../../src/core/utils";
import { createSuite } from "./harness";

const { test, run } = createSuite("relay-transaction-wait");

test("waits by hash without enabling ethers transaction replacement detection", () => {
  const transactionHash = `0x${"ab".repeat(32)}`;
  const receiptPromise = Promise.resolve({ transactionHash } as providers.TransactionReceipt);
  const calls: Array<{ transactionHash: string; confirmations?: number }> = [];
  const provider = {
    waitForTransaction: (hash: string, confirmations?: number) => {
      calls.push({ transactionHash: hash, confirmations });
      return receiptPromise;
    },
  } as providers.JsonRpcProvider;

  const result = waitForAnvilTransaction(provider, transactionHash);

  assert.equal(result, receiptPromise);
  assert.deepEqual(calls, [{ transactionHash, confirmations: 1 }]);
});

run();
