/**
 * Registry manifest -> initialize() arguments.
 *
 * The storage-backed registries (`CTMRegistry` / `CoreRegistry`,
 * contracts/upgrades/registry) are fixed, audited-once implementations initialized exactly
 * once with a full manifest struct. This module translates the committed manifest JSON
 * (scripts/registry-manifests/*.json — the reviewable per-upgrade artifact) into the
 * `initialize()` argument objects ethers encodes against the contract ABI.
 *
 * Enum identifiers in the manifest are NAMES; their numeric values are parsed from the
 * canonical Solidity sources at runtime (never hardcoded), so enum reordering upstream cannot
 * silently skew the encoding.
 */

import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";

const l1ContractsDir = path.resolve(__dirname, "../../../..");

// Packed SemVer layout (contracts/common/libraries/SemVer.sol): major << 64 | minor << 32 | patch.
export function packSemVer(version: string): bigint {
  const [major, minor, patch] = version.split(".").map((p) => BigInt(p));
  return (major << 64n) | (minor << 32n) | patch;
}

/** Parses `enum <name> { A, B, ... }` from a Solidity source into a name -> index map. */
function parseSolidityEnum(relSourcePath: string, enumName: string): Record<string, number> {
  const source = fs.readFileSync(path.join(l1ContractsDir, relSourcePath), "utf-8");
  const match = source.match(new RegExp(`enum\\s+${enumName}\\s*\\{([^}]*)\\}`));
  if (!match) {
    throw new Error(`enum ${enumName} not found in ${relSourcePath}`);
  }
  const members = match[1]
    .split(",")
    .map((m) =>
      m
        .split("\n")
        .filter((line) => !line.trim().startsWith("//"))
        .join("")
        .trim()
    )
    .filter((m) => m.length > 0);
  return Object.fromEntries(members.map((m, i) => [m, i]));
}

const IDENTIFIERS_SOL = "contracts/upgrades/registry/ContractIdentifiers.sol";
const COMPLEX_UPGRADER_SOL = "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

function enumValue(map: Record<string, number>, name: string, enumName: string): number {
  const value = map[name];
  if (value === undefined) {
    throw new Error(`unknown ${enumName} member "${name}"`);
  }
  return value;
}

// Loose manifest typing: the JSON schema is owned by the emit side of the upgrade runner.
/* eslint-disable @typescript-eslint/no-explicit-any */

/** `CoreRegistry.CoreRegistryManifest` initialize argument from the manifest JSON. */
export function coreInitArgs(manifest: any): any {
  const ecosystemContract = parseSolidityEnum(IDENTIFIERS_SOL, "EcosystemContract");

  const entries: Array<[string, any]> = Object.entries(manifest.core.contracts);
  const contractRows = entries.map(([name, e]) => ({
    key: enumValue(ecosystemContract, name, "EcosystemContract"),
    proxy: e.proxy,
    implNew: e.implNew ?? ethers.constants.AddressZero,
  }));
  const codehashPins = entries
    .filter(([, e]) => e.implNew && e.implNewCodehash)
    .map(([, e]) => ({ target: e.implNew, expectedCodehash: e.implNewCodehash }));

  return {
    oldProtocolVersion: packSemVer(manifest.oldVersion),
    newProtocolVersion: packSemVer(manifest.newVersion),
    proxyAdmin: manifest.core.proxyAdmin,
    eraCTMRegistry: manifest.core.ctmRegistries.era,
    zksyncOSCTMRegistry: manifest.core.ctmRegistries.zksyncOS,
    contractRows,
    codehashPins,
  };
}

/** `CTMRegistry.CTMRegistryManifest` initialize argument from one `manifest.ctms[]` entry. */
export function ctmInitArgs(manifest: any, ctm: any): any {
  const ctmContract = parseSolidityEnum(IDENTIFIERS_SOL, "CTMContract");
  const coreContract = parseSolidityEnum(IDENTIFIERS_SOL, "CoreContract");
  const upgradeType = parseSolidityEnum(COMPLEX_UPGRADER_SOL, "ContractUpgradeType");

  const oldV = packSemVer(manifest.oldVersion);
  const newV = packSemVer(manifest.newVersion);

  // Non-facet CTM contracts, new-version addresses only.
  const contractEntries: Array<[string, any]> = Object.entries(ctm.contracts);
  const ctmAddressRows = contractEntries
    .filter(([, e]) => e.new)
    .map(([name, e]) => ({
      key: enumValue(ctmContract, name, "CTMContract"),
      protocolVersion: newV,
      value: e.new,
    }));

  // Old side: the upgrade PLAN (zero address = added). New side: the complete installed set.
  const facetRows = [
    ...ctm.facets.plan.map((f: any) => ({
      facet: enumValue(ctmContract, f.name, "CTMContract"),
      protocolVersion: oldV,
      facetAddress: f.oldAddress,
      selectorList: f.selectors ?? [],
    })),
    ...ctm.facets.installed.map((f: any) => ({
      facet: enumValue(ctmContract, f.name, "CTMContract"),
      protocolVersion: newV,
      facetAddress: f.address,
      selectorList: f.selectors ?? [],
    })),
  ];

  const freezabilityRows = Object.entries(ctm.facetFreezability).map(([name, freezable]) => ({
    facet: enumValue(ctmContract, name, "CTMContract"),
    isFreezable: freezable,
  }));

  const l2DeploymentRows = ctm.l2.forceDeployments.map((d: any) => ({
    key: enumValue(coreContract, d.contract, "CoreContract"),
    info: {
      upgradeType: enumValue(upgradeType, d.upgradeType, "ContractUpgradeType"),
      deployedBytecodeInfo: d.deployedBytecodeInfo,
      newAddress: d.newAddress,
    },
    bytecodeHash: d.bytecodeHash,
  }));

  const codehashPins = [
    ...contractEntries
      .filter(([, e]) => e.new && e.newCodehash)
      .map(([, e]) => ({ target: e.new, expectedCodehash: e.newCodehash })),
    ...ctm.facets.installed
      .filter((f: any) => f.codehash)
      .map((f: any) => ({ target: f.address, expectedCodehash: f.codehash })),
  ];

  return {
    isZKsyncOS: ctm.isZKsyncOS,
    oldProtocolVersion: oldV,
    newProtocolVersion: newV,
    ctmProxy: ctm.ctmProxy,
    ctmAddressRows,
    verifierRows: [{ protocolVersion: newV, verifier: ctm.verifierNew }],
    facetRows,
    freezabilityRows,
    l2DeploymentRows,
    l2UpgradeDelegateTo: ctm.l2.delegateTo,
    l2UpgradeDelegateCalldata: ctm.l2.delegateCalldata,
    factoryDepHashes: ctm.l2.factoryDepHashes.map((h: string) => ethers.BigNumber.from(h)),
    bootloaderHash: ctm.l2.baseSystemContracts.bootloader,
    defaultAccountHash: ctm.l2.baseSystemContracts.defaultAccount,
    evmEmulatorHash: ctm.l2.baseSystemContracts.evmEmulator,
    fixedForceDeploymentsData: ctm.l2.fixedForceDeploymentsData,
    genesisUpgrade: ctm.genesis.genesisUpgrade,
    genesisBatchHash: ctm.genesis.batchHash,
    genesisBatchCommitment: ctm.genesis.batchCommitment,
    genesisIndexRepeatedStorageChanges: ctm.genesis.indexRepeatedStorageChanges,
    codehashPins,
  };
}
