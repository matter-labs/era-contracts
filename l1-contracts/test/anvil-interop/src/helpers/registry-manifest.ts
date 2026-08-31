/**
 * Registry manifest -> initialize() arguments.
 *
 * The storage-backed, write-once upgrade objects (`CTMRelease` / `CTMTransition` /
 * `CoreRegistry`, contracts/upgrades/registry) are fixed, audited-once implementations
 * initialized exactly once with a full manifest struct. This module translates the committed
 * manifest JSON (scripts/registry-manifests/*.json — the reviewable per-upgrade artifact) into
 * the `initialize()` argument objects ethers encodes against the contract ABIs:
 *
 *   - `CTMRelease.ReleaseManifest` — what a chain at the target release IS: facet rows with
 *     INLINE MANDATORY codehash pins beside every address (routing is read from each pinned
 *     facet's own self-description). Version- and VM-flag-independent (VM identity lives in
 *     the pinned DiamondInit immutable).
 *   - `CTMTransition.TransitionManifest` — how the current release becomes the target release.
 *     Carries NO facet swaps and NO hash changes: the delta is DERIVED on-chain from the
 *     `(fromRelease, newRelease)` pair at initialization. What is authored: version edge,
 *     pinned verifier + upgrade engine, schedule, and the typed `L2UpgradePlan`.
 *   - `CoreRegistry.CoreRegistryManifest` — the NAMED ecosystem inventory
 *     (`EcosystemProxyUpgrades`): one slot per ecosystem proxy, source-checked rows with inline
 *     pins in the participating slots, zero `implNew` in the explicitly-not-upgraded ones.
 *
 * Enum identifiers and inventory slot names in the manifest are NAMES; enum values and struct
 * field lists are parsed from the canonical Solidity sources at runtime (never hardcoded), so
 * upstream reordering or renaming cannot silently skew the encoding.
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

const COMPLEX_UPGRADER_SOL = "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
const REGISTRY_TYPES_SOL = "contracts/upgrades/registry/RegistryTypes.sol";

function enumValue(map: Record<string, number>, name: string, enumName: string): number {
  const value = map[name];
  if (value === undefined) {
    throw new Error(`unknown ${enumName} member "${name}"`);
  }
  return value;
}

/** Parses `struct <name> { <type> <field>; ... }` into its ordered field-name list. */
function parseSolidityStructFields(relSourcePath: string, structName: string): string[] {
  const source = fs.readFileSync(path.join(l1ContractsDir, relSourcePath), "utf-8");
  const match = source.match(new RegExp(`struct\\s+${structName}\\s*\\{([^}]*)\\}`));
  if (!match) {
    throw new Error(`struct ${structName} not found in ${relSourcePath}`);
  }
  return match[1]
    .split(";")
    .map((decl) =>
      decl
        .split("\n")
        .filter((line) => !line.trim().startsWith("//"))
        .join(" ")
        .trim()
    )
    .filter((decl) => decl.length > 0)
    .map((decl) => decl.split(/\s+/).pop() as string);
}

/** An inert named-inventory slot: the explicit "not upgraded" statement. */
function zeroProxyUpgradeRow(): any {
  return {
    proxy: ethers.constants.AddressZero,
    expectedOldImpl: ethers.constants.AddressZero,
    implNew: { addr: ethers.constants.AddressZero, codehash: ethers.constants.HashZero },
    initCalldata: "0x",
  };
}

/**
 * Builds a named proxy-upgrade inventory (`EcosystemProxyUpgrades` / `CTMProxyUpgrades`) from
 * rows keyed by SLOT NAME. Slot names are the Solidity struct field names, parsed from the
 * source; a row keyed by anything else refuses to encode, and every unnamed slot encodes as the
 * explicit zero ("not upgraded") row.
 */
export function namedProxyUpgrades(structName: string, rows: Record<string, any>): any {
  const fields = parseSolidityStructFields(REGISTRY_TYPES_SOL, structName);
  const upgrades: Record<string, any> = {};
  for (const field of fields) {
    upgrades[field] = zeroProxyUpgradeRow();
  }
  for (const [name, row] of Object.entries(rows ?? {})) {
    if (!fields.includes(name)) {
      throw new Error(`unknown ${structName} slot "${name}" (known: ${fields.join(", ")})`);
    }
    upgrades[name] = row;
  }
  return upgrades;
}

// Loose manifest typing: the JSON schema is owned by the emit side of the upgrade runner.
/* eslint-disable @typescript-eslint/no-explicit-any */

/** `CoreRegistry.CoreRegistryManifest` initialize argument from the manifest JSON. */
export function coreInitArgs(manifest: any): any {
  // The JSON keys under `core.contracts` ARE the `EcosystemProxyUpgrades` slot names — one
  // naming scheme end to end, with unknown keys refused at encode time.
  const entries: Array<[string, any]> = Object.entries(manifest.core.contracts);
  const rows = Object.fromEntries(
    entries.map(([name, e]) => [
      name,
      {
        proxy: e.proxy,
        expectedOldImpl: e.expectedOldImpl ?? ethers.constants.AddressZero,
        implNew: {
          addr: e.implNew ?? ethers.constants.AddressZero,
          codehash: e.implNewCodehash ?? ethers.constants.HashZero,
        },
        initCalldata: e.initCalldata ?? "0x",
      },
    ])
  );

  return { ecosystemProxyUpgrades: namedProxyUpgrades("EcosystemProxyUpgrades", rows) };
}

/** `CTMRelease.ReleaseManifest` initialize argument from one `manifest.ctms[]` entry. */
export function releaseInitArgs(ctm: any): any {
  const release = ctm.release;

  // Inline mandatory pin per facet row; routing is read from each pinned facet's own
  // self-description, never stored.
  const genesisFacets = release.genesisFacets.map((f: any) => ({
    facet: { addr: f.address, codehash: f.codehash },
    isFreezable: f.isFreezable,
  }));

  return {
    diamondInit: { addr: release.diamondInit.address, codehash: release.diamondInit.codehash },
    verifier: { addr: release.verifier.address, codehash: release.verifier.codehash },
    genesisUpgrade: { addr: release.genesis.genesisUpgrade.address, codehash: release.genesis.genesisUpgrade.codehash },
    genesisFacets,
    // `ReleaseGenesisData` — the block a release shares with the deploy-time `GenesisConfig`.
    genesis: {
      bootloaderHash: release.baseSystemContracts.bootloader,
      defaultAccountHash: release.baseSystemContracts.defaultAccount,
      evmEmulatorHash: release.baseSystemContracts.evmEmulator,
      fixedForceDeploymentsData: release.fixedForceDeploymentsData,
      genesisBatchHash: release.genesis.batchHash,
      genesisBatchCommitment: release.genesis.batchCommitment,
      genesisIndexRepeatedStorageChanges: release.genesis.indexRepeatedStorageChanges,
    },
  };
}

/**
 * `CTMTransition.TransitionManifest` initialize argument from one `manifest.ctms[]` entry.
 * `newRelease` is the just-deployed `CTMRelease` address — passed in by the runner rather than
 * read from the JSON, since the release must be deployed first anyway (transition
 * initialization validates it and derives the facet/hash delta from the release pair).
 */
export function transitionInitArgs(manifest: any, ctm: any, newRelease: string): any {
  // Release provenance is enforced by the CTM's stored `releaseCodehash` at `setCurrentRelease`
  // time, not by the transition manifest — which is why the runner checks the freshly deployed
  // release against that same anchor.
  const upgradeType = parseSolidityEnum(COMPLEX_UPGRADER_SOL, "ContractUpgradeType");
  const transition = ctm.transition;

  const deployments = transition.l2Plan.deployments.map((d: any) => ({
    upgradeType: enumValue(upgradeType, d.upgradeType, "ContractUpgradeType"),
    deployedBytecodeInfo: d.deployedBytecodeInfo,
    newAddress: d.newAddress,
  }));

  return {
    // The registry-driven hop departs from the BOOTSTRAP edge's target version (the bootstrap
    // crossed manifest.oldVersion -> manifest.bootstrapVersion first).
    oldProtocolVersion: packSemVer(manifest.bootstrapVersion),
    newProtocolVersion: packSemVer(manifest.newVersion),
    fromRelease: transition.fromRelease,
    newRelease,
    upgradeEngine: { addr: transition.upgradeEngine.address, codehash: transition.upgradeEngine.codehash },
    // The named CTM-domain inventory; the local hop upgrades chain state only, so the manifest
    // carries no slots and every one encodes as the explicit zero ("not upgraded") row.
    ctmProxyUpgrades: namedProxyUpgrades("CTMProxyUpgrades", transition.ctmProxyUpgrades ?? {}),
    oldProtocolVersionDeadline: ethers.BigNumber.from(transition.oldProtocolVersionDeadline),
    upgradeTimestamp: transition.upgradeTimestamp,
    l2Plan: {
      deployments,
      delegateTo: transition.l2Plan.delegateTo,
      delegateCalldata: transition.l2Plan.delegateCalldata,
      factoryDepHashes: transition.l2Plan.factoryDepHashes.map((h: string) => ethers.BigNumber.from(h)),
    },
  };
}
