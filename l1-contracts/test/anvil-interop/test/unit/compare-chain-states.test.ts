import * as assert from "assert/strict";
import { compareChainState, ctmVersionKeyedBlockSlots } from "../../compare-chain-states";
import { createSuite } from "./harness";

const { test, run } = createSuite("compare-chain-states");

const CTM = "0x79e66ae4354861a4d5a95c80f8a0d933389c6d07";
// newChainCreationParamsBlock for the current OS genesis version; the drift tests below would
// otherwise break on every genesis protocol-version bump.
const [, CREATION_BLOCK_SLOT] = ctmVersionKeyedBlockSlots();

function state(storage: Record<string, string>, code = "0x6000") {
  return { accounts: { [CTM]: { storage, code } } };
}

test("derives CTM version-keyed block slots from the packed protocol version", () => {
  // newChainCreationParamsBlock[SemVer.packSemVer(0, 33, 1)], from the v33.1 CI snapshots.
  assert.equal(
    ctmVersionKeyedBlockSlots({ major: 0, minor: 33, patch: 1 })[1],
    "0x383fd630e996ce1341ac157dd326cc2e0f5b9ded49b0f2fc3179ae92b8f9cfef"
  );
});

test("ignores CTM registration block drift", () => {
  for (const [committed, generated] of [
    ["0x50", "0x28"],
    ["0x102", "0x93"],
  ]) {
    assert.deepEqual(
      compareChainState(
        state({ [CREATION_BLOCK_SLOT]: committed }),
        state({ [CREATION_BLOCK_SLOT]: generated }),
        "state.json",
        new Set()
      ),
      []
    );
  }
});

test("still detects other CTM storage changes alongside block drift", () => {
  const diffs = compareChainState(
    state({ [CREATION_BLOCK_SLOT]: "0x50", "0x01": "0x01" }),
    state({ [CREATION_BLOCK_SLOT]: "0x28", "0x01": "0x02" }),
    "state.json",
    new Set()
  );
  assert.ok(diffs.some((diff) => diff.includes("slot 0x01: 0x01 != 0x02")));
  assert.ok(diffs.every((diff) => !diff.includes(CREATION_BLOCK_SLOT)));
});

test("still detects CTM bytecode changes", () => {
  const diffs = compareChainState(state({}, "0x6000"), state({}, "0x6001"), "state.json", new Set());
  assert.ok(diffs.some((diff) => diff.includes("code differs")));
});

run();
