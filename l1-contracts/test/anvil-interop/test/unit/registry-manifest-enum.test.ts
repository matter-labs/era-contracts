/**
 * Unit tests for the manifest helper's reading of `L2EcosystemContract`.
 *
 * The release's L2 bytecode table has exactly one slot per enum member and the contract refuses
 * any other length, so the helper's member list must be the enum's — including members that sit
 * below explanatory comments, which may legitimately contain braces and commas.
 *
 * Run with: yarn test:unit registry-manifest
 */

import * as assert from "assert/strict";
import * as fs from "fs";
import * as path from "path";
import { l2BytecodeInfoSlots } from "../../src/helpers/registry-manifest";
import { createSuite } from "./harness";

const { test, run } = createSuite("registry-manifest-enum");

// An independent, line-based reading of the enum: identifier-only lines between the declaration
// and the first line that is exactly `}`. Comment lines are excluded by construction.
function enumMembersByLine(): string[] {
  const source = fs.readFileSync(
    path.join(__dirname, "../../../../contracts/upgrades/registry/libraries/ContractIdentifiers.sol"),
    "utf-8"
  );
  const lines = source.split("\n");
  const start = lines.findIndex((l) => /^\s*enum\s+L2EcosystemContract\s*\{/.test(l));
  assert.notEqual(start, -1, "enum L2EcosystemContract not found");
  const members: string[] = [];
  for (const line of lines.slice(start + 1)) {
    if (/^\s*\}\s*$/.test(line)) {
      break;
    }
    const m = line.match(/^\s*([A-Za-z_]\w*)\s*,?\s*$/);
    if (m) {
      members.push(m[1]);
    }
  }
  return members;
}

test("emits one slot per enum member", () => {
  const members = enumMembersByLine();
  assert.equal(l2BytecodeInfoSlots({}).length, members.length);
});

// Regression: a `{…}` inside a member's comment used to end the enum body early and drop every
// member below it, so the table came out one slot short and the release constructor refused it.
test("keeps the members below a comment that contains braces", () => {
  const members = enumMembersByLine();
  const last = members[members.length - 1];
  const slots = l2BytecodeInfoSlots({ [last]: "0x01" });
  assert.equal(slots[slots.length - 1], "0x01", `${last} must map to the last slot`);
  assert.equal(slots.filter((s) => s === "0x01").length, 1);
});

run();
