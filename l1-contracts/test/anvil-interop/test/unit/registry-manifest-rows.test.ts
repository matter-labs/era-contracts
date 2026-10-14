/**
 * Unit tests for the harness's `ProxyUpgradeRow` and `OperationManifest` encoders.
 *
 * Structs are encoded against the contract ABI by field name, so a helper that drifts from the
 * Solidity struct only fails deep inside an anvil run. These cases pin both shapes to the structs
 * in `RegistryTypes.sol`.
 *
 * Run with: yarn test:unit registry-manifest-rows
 */

import * as assert from "assert/strict";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import {
  coreInitArgs,
  operationInitArgs,
  proxyUpgradeSlotIndex,
  proxyUpgradeSlots,
} from "../../src/helpers/registry-manifest";
import { createSuite } from "./harness";

const { test, run } = createSuite("registry-manifest-rows");

const REGISTRY_TYPES_SOL = path.join(__dirname, "../../../../contracts/upgrades/registry/RegistryTypes.sol");

// Distinct, recognizable addresses for the rows under test.
const address = (n: number) => ethers.utils.getAddress(ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 20));

/** The member names of `struct <name> { ... }`, comments stripped. */
function solidityStructFields(name: string): string[] {
  const source = fs
    .readFileSync(REGISTRY_TYPES_SOL, "utf-8")
    .replace(/\/\/.*$/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "");
  const match = source.match(new RegExp(`struct\\s+${name}\\s*\\{([^}]*)\\}`));
  assert.ok(match, `struct ${name} not found in RegistryTypes.sol`);
  return match[1]
    .split(";")
    .map((declaration) => declaration.trim())
    .filter((declaration) => declaration.length > 0)
    .map((declaration) => declaration.split(/\s+/).pop() as string);
}

function assertRowShape(row: object, where: string): void {
  assert.deepEqual(
    Object.keys(row).sort(),
    solidityStructFields("ProxyUpgradeRow").sort(),
    `${where}: fields differ from the Solidity ProxyUpgradeRow`
  );
}

test("an inert slot carries exactly the Solidity row's fields, in both domains", () => {
  for (const enumName of ["CTMContract", "L1EcosystemContract"]) {
    const slots = proxyUpgradeSlots(enumName, {});
    slots.forEach((slot, i) => assertRowShape(slot, `${enumName}[${i}]`));
  }
});

test("a core manifest entry encodes exactly the Solidity row's fields, in its own slot", () => {
  const entry = { proxy: address(1), expectedOldImpl: address(2), implNew: address(3) };
  const { proxyUpgrades } = coreInitArgs({ core: { contracts: { L1MessageRoot: entry } } });
  const row = proxyUpgrades[proxyUpgradeSlotIndex("L1EcosystemContract", "L1MessageRoot")];
  assertRowShape(row, "core L1MessageRoot row");
  assert.deepEqual(row, { ...entry, callInitializeUpgrade: false });
});

test("the operation manifest carries exactly the Solidity struct's fields, every CTM-domain slot inert", () => {
  const args = operationInitArgs({ transition: {} }, address(1), address(2), address(3));
  assert.deepEqual(
    Object.keys(args).sort(),
    solidityStructFields("OperationManifest").sort(),
    "operation init args: fields differ from the Solidity OperationManifest"
  );
  assert.deepEqual(
    [args.coreTransition, args.ctmTransition, args.timer],
    [address(1), address(2), address(3)],
    "operation init args name the objects they were given"
  );
  assert.equal(args.ctmInfrastructure.length, proxyUpgradeSlots("CTMContract", {}).length);
  args.ctmInfrastructure.forEach((row: { implNew: string }, i: number) => {
    assertRowShape(row, `CTMContract[${i}]`);
    assert.equal(row.implNew, ethers.constants.AddressZero, `CTMContract[${i}] must be inert`);
  });
});

test("an unknown slot name refuses to resolve", () => {
  assert.throws(() => proxyUpgradeSlotIndex("CTMContract", "NotAContract"), /unknown CTMContract member/);
});

run();
