/**
 * Unit tests for the bootstrap bundle's closing rule (`assertBundleClosesWithCompletionCheck` in
 * `src/helpers/bootstrap-upgrade-stage.ts`): the bundle closes with the completion check
 * `validateApplied()` on the migration, and nothing runs after it, so a failing check reverts the
 * whole edge.
 *
 * The rule compares target, value and calldata bytes without decoding, so the calldata here is an
 * opaque 4-byte tag standing in for `validateApplied()`.
 *
 * Run with: yarn test:unit bootstrap-upgrade-stage
 */

import * as assert from "assert/strict";
import { ethers } from "ethers";
import { assertBundleClosesWithCompletionCheck } from "../../src/helpers/bootstrap-upgrade-stage";
import type { GovernanceCall } from "../../src/helpers/governance-bundle";
import { createSuite } from "./harness";

const { test, run } = createSuite("bootstrap-upgrade-stage");

const address = (n: number) => ethers.utils.getAddress(ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 20));

const MIGRATION = address(0xb0);
const CTM = address(0xc7);
// Stand-ins for `migrate()`, the completion check that follows it, and a handover.
const MIGRATE = "0xaabbccdd";
const VALIDATE_APPLIED = "0x11223344";
const TRANSFER_OWNERSHIP = "0x55667788";

const call = (target: string, data: string, value = 0): GovernanceCall => ({
  target,
  value: ethers.BigNumber.from(value),
  data,
});

const HANDOVER = call(CTM, TRANSFER_OWNERSHIP);
const NOT_CLOSED = /the bootstrap bundle does not close with 0x[0-9a-fA-F]{40}\.validateApplied\(\)/;

test("accepts a bundle closing with migrate() and then the completion check on the migration", () => {
  assertBundleClosesWithCompletionCheck(
    [HANDOVER, call(MIGRATION, MIGRATE), call(MIGRATION, VALIDATE_APPLIED)],
    MIGRATION,
    VALIDATE_APPLIED
  );
});

test("compares the target and the calldata case-insensitively", () => {
  assertBundleClosesWithCompletionCheck(
    [call(MIGRATION.toLowerCase(), VALIDATE_APPLIED.toUpperCase())],
    MIGRATION,
    VALIDATE_APPLIED
  );
});

test("refuses an empty bundle", () => {
  assert.throws(
    () => assertBundleClosesWithCompletionCheck([], MIGRATION, VALIDATE_APPLIED),
    /\(got an empty bundle\)/
  );
});

test("refuses a bundle that ends in migrate() without the completion check", () => {
  assert.throws(
    () => assertBundleClosesWithCompletionCheck([HANDOVER, call(MIGRATION, MIGRATE)], MIGRATION, VALIDATE_APPLIED),
    new RegExp(`${NOT_CLOSED.source} \\(got target ${MIGRATION}, selector ${MIGRATE}\\)`)
  );
});

test("refuses a call after the completion check", () => {
  assert.throws(
    () =>
      assertBundleClosesWithCompletionCheck(
        [call(MIGRATION, MIGRATE), call(MIGRATION, VALIDATE_APPLIED), HANDOVER],
        MIGRATION,
        VALIDATE_APPLIED
      ),
    NOT_CLOSED
  );
});

test("refuses the completion check sent to another target", () => {
  assert.throws(
    () =>
      assertBundleClosesWithCompletionCheck(
        [call(MIGRATION, MIGRATE), call(CTM, VALIDATE_APPLIED)],
        MIGRATION,
        VALIDATE_APPLIED
      ),
    NOT_CLOSED
  );
});

test("refuses a closing completion check that carries value", () => {
  assert.throws(
    () =>
      assertBundleClosesWithCompletionCheck(
        [call(MIGRATION, MIGRATE), call(MIGRATION, VALIDATE_APPLIED, 1)],
        MIGRATION,
        VALIDATE_APPLIED
      ),
    NOT_CLOSED
  );
});

run();
