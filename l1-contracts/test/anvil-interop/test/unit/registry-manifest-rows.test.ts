/**
 * Unit tests for the harness's `ProxyUpgradeRow` and `BootstrapManifest` encoders.
 *
 * Structs are encoded against the contract ABI by field name, so a helper that drifts from the
 * Solidity struct only fails deep inside an anvil run. These cases pin both shapes to the structs
 * in `RegistryTypes.sol`, and the bootstrap manifest to its mandatory `ServerNotifier` slot.
 *
 * Run with: yarn test:unit registry-manifest-rows
 */

import * as assert from "assert/strict";
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { bootstrapInitArgs } from "../../src/helpers/bootstrap-upgrade-stage";
import {
  coreInitArgs,
  packSemVer,
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

test("the bootstrap manifest carries the CTM and ServerNotifier rows, every other slot inert", () => {
  const ctmRow = { proxy: address(10), expectedOldImpl: address(11), implNew: address(12) };
  const notifierRow = {
    proxy: address(20),
    expectedOldImpl: address(21),
    implNew: address(22),
    callInitializeUpgrade: false,
  };
  const args = bootstrapInitArgs(
    {
      oldVersion: "0.34.0",
      bootstrap: {
        ctmImpl: ctmRow,
        oldProtocolVersionDeadline: "0x01",
        upgradeEngine: { address: address(30) },
      },
    },
    packSemVer,
    {
      ctmProxy: ctmRow.proxy,
      proxyAdmin: address(40),
      currentRelease: address(41),
      ctmExecutor: address(42),
      coreExecutor: address(47),
      governance: address(43),
      coordinator: address(44),
      upgradeTimer: address(45),
      delegateComposer: address(46),
      l2Delegate: { deployedBytecodeInfo: "0x" },
      serverNotifierRow: notifierRow,
    }
  );
  assert.deepEqual(
    Object.keys(args).sort(),
    solidityStructFields("BootstrapManifest").sort(),
    "bootstrap init args: fields differ from the Solidity BootstrapManifest"
  );
  const ctmSlot = proxyUpgradeSlotIndex("CTMContract", "ChainTypeManager");
  const notifierSlot = proxyUpgradeSlotIndex("CTMContract", "ServerNotifier");
  assert.deepEqual(args.ctmProxyUpgrades[ctmSlot], { ...ctmRow, callInitializeUpgrade: false });
  assert.deepEqual(args.ctmProxyUpgrades[notifierSlot], notifierRow);
  args.ctmProxyUpgrades.forEach((row: { implNew: string }, i: number) => {
    assertRowShape(row, `CTMContract[${i}]`);
    if (i !== ctmSlot && i !== notifierSlot) {
      assert.equal(row.implNew, ethers.constants.AddressZero, `CTMContract[${i}] must be inert`);
    }
  });
});

test("an unknown slot name refuses to resolve", () => {
  assert.throws(() => proxyUpgradeSlotIndex("CTMContract", "NotAContract"), /unknown CTMContract member/);
});

run();
