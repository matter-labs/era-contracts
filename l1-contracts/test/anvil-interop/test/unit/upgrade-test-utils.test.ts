/**
 * Unit tests for `mismatch` (`src/helpers/upgrade-test-utils.ts`), the comparison every live
 * post-state assertion of the upgrade runners reports through: a comparison that wrongly agreed
 * would let those assertions pass on any state.
 *
 * Run with: yarn test:unit upgrade-test-utils
 */

import * as assert from "assert/strict";
import { ethers } from "ethers";
import { mismatch } from "../../src/helpers/upgrade-test-utils";
import { createSuite } from "./harness";

const { test, run } = createSuite("upgrade-test-utils");

const address = (n: number) => ethers.utils.getAddress(ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 20));

const EXECUTOR = address(0xe1);
const OTHER = address(0xe2);

test("agrees on addresses that differ only in case", () => {
  assert.deepEqual(mismatch("CTM owner()", EXECUTOR.toLowerCase(), EXECUTOR), []);
});

test("reports differing addresses with both values", () => {
  assert.deepEqual(mismatch("CTM owner()", OTHER, EXECUTOR), [`  CTM owner(): live ${OTHER}, expected ${EXECUTOR}`]);
});

test("compares BigNumbers by value and prints them as hex", () => {
  assert.deepEqual(mismatch("CTM protocolVersion()", ethers.BigNumber.from(16), ethers.BigNumber.from("0x10")), []);
  assert.deepEqual(mismatch("CTM protocolVersion()", ethers.BigNumber.from(1), ethers.BigNumber.from(2)), [
    "  CTM protocolVersion(): live 0x01, expected 0x02",
  ]);
});

test("reports differing booleans", () => {
  assert.deepEqual(mismatch("migration executed()", false, true), [
    "  migration executed(): live false, expected true",
  ]);
});

run();
