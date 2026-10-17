/**
 * Unit tests for the harness's `ProxyUpgradeRow` and `ProxyUpgradeTransitionManifest` encoders.
 *
 * Structs are encoded against the contract ABI by field name, so a helper that drifts from the
 * Solidity struct only fails deep inside an anvil run. These cases pin both shapes to the structs
 * in `RegistryTypes.sol`, and the domain tag to its `ProxyUpgradeDomain` enum.
 *
 * Run with: yarn test:unit registry-manifest-rows
 */

import * as assert from "assert/strict";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import {
  coreInitArgs,
  ctmInfrastructureInitArgs,
  proxyUpgradeDomain,
  proxyUpgradeSlotIndex,
  proxyUpgradeSlots,
} from "../../src/helpers/registry-manifest";
import { createSuite } from "./harness";

const { test, run } = createSuite("registry-manifest-rows");

const REGISTRY_TYPES_SOL = path.join(__dirname, "../../../../contracts/upgrades/registry/RegistryTypes.sol");

// Distinct, recognizable addresses for the rows under test.
const address = (n: number) => ethers.utils.getAddress(ethers.utils.hexZeroPad(ethers.utils.hexlify(n), 20));

/** `REGISTRY_TYPES_SOL` with its comments stripped. */
function registryTypesSource(): string {
  return fs
    .readFileSync(REGISTRY_TYPES_SOL, "utf-8")
    .replace(/\/\/.*$/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "");
}

/** The member names of `struct <name> { ... }`, comments stripped. */
function solidityStructFields(name: string): string[] {
  const source = registryTypesSource();
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

/** An independent reading of `enum ProxyUpgradeDomain`: its members in declaration order. */
function proxyUpgradeDomainMembers(): string[] {
  const match = registryTypesSource().match(/enum\s+ProxyUpgradeDomain\s*\{([^}]*)\}/);
  assert.ok(match, "enum ProxyUpgradeDomain not found in RegistryTypes.sol");
  return match[1]
    .split(",")
    .map((member) => member.trim())
    .filter((member) => member.length > 0);
}

function assertTransitionManifestShape(args: object, where: string): void {
  assert.deepEqual(
    Object.keys(args).sort(),
    solidityStructFields("ProxyUpgradeTransitionManifest").sort(),
    `${where}: fields differ from the Solidity ProxyUpgradeTransitionManifest`
  );
}

test("the domain tag is the ProxyUpgradeDomain member's index", () => {
  const members = proxyUpgradeDomainMembers();
  assert.equal(proxyUpgradeDomain("Core"), members.indexOf("Core"));
  assert.equal(proxyUpgradeDomain("CTM"), members.indexOf("CTM"));
  assert.notEqual(proxyUpgradeDomain("Core"), proxyUpgradeDomain("CTM"));
});

test("a core manifest encodes a Core-domain transition manifest, the row in its own slot", () => {
  const entry = { proxy: address(1), expectedOldImpl: address(2), implNew: address(3) };
  const args = coreInitArgs({ core: { contracts: { L1MessageRoot: entry } } });
  assertTransitionManifestShape(args, "core init args");
  assert.equal(args.domain, proxyUpgradeDomain("Core"));
  assert.equal(args.proxyUpgrades.length, proxyUpgradeSlots("L1EcosystemContract", {}).length);
  const row = args.proxyUpgrades[proxyUpgradeSlotIndex("L1EcosystemContract", "L1MessageRoot")];
  assertRowShape(row, "core L1MessageRoot row");
  assert.deepEqual(row, { ...entry, callInitializeUpgrade: false });
});

test("CTM infrastructure rows encode a CTM-domain transition manifest indexed by CTMContract", () => {
  const entry = { proxy: address(4), expectedOldImpl: address(5), implNew: address(6), callInitializeUpgrade: true };
  const args = ctmInfrastructureInitArgs({ infrastructure: { contracts: { ServerNotifier: entry } } });
  assertTransitionManifestShape(args, "CTM infrastructure init args");
  assert.equal(args.domain, proxyUpgradeDomain("CTM"));
  assert.equal(args.proxyUpgrades.length, proxyUpgradeSlots("CTMContract", {}).length);
  args.proxyUpgrades.forEach((row: { implNew: string }, i: number) => {
    assertRowShape(row, `CTMContract[${i}]`);
    if (i !== proxyUpgradeSlotIndex("CTMContract", "ServerNotifier")) {
      assert.equal(row.implNew, ethers.constants.AddressZero, `CTMContract[${i}] must be inert`);
    }
  });
  assert.deepEqual(args.proxyUpgrades[proxyUpgradeSlotIndex("CTMContract", "ServerNotifier")], entry);
});

test("a CTM entry without infrastructure rows encodes no object; an unknown member refuses", () => {
  // The CTM-domain object refuses an empty participating set, so there is nothing to deploy.
  assert.equal(ctmInfrastructureInitArgs({ transition: {} }), undefined);
  assert.equal(ctmInfrastructureInitArgs({ infrastructure: { contracts: {} } }), undefined);
  assert.throws(
    () => ctmInfrastructureInitArgs({ infrastructure: { contracts: { L1MessageRoot: { proxy: address(1) } } } }),
    /unknown CTMContract member "L1MessageRoot"/
  );
});

test("an unknown slot name refuses to resolve", () => {
  assert.throws(() => proxyUpgradeSlotIndex("CTMContract", "NotAContract"), /unknown CTMContract member/);
});

run();
