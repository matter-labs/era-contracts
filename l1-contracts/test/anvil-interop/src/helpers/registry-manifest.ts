/**
 * Registry manifest -> initialize() arguments.
 *
 * The storage-backed, write-once upgrade objects (`CTMRelease` / `CTMTransition` /
 * `CoreRegistry`, contracts/upgrades/registry) are fixed, audited-once implementations
 * initialized exactly once with a full manifest struct. This module translates the committed
 * manifest JSON (scripts/registry-manifests/*.json — the reviewable per-upgrade artifact) into
 * the `initialize()` argument objects ethers encodes against the contract ABIs:
 *
 *   - `CTMRelease.ReleaseManifest` — what a chain at the target release IS: facet rows naming
 *     each facet by address (routing is read from the facet's own self-description).
 *     Version- and VM-flag-independent (VM identity lives in the DiamondInit's immutable).
 *   - `CTMTransition.TransitionManifest` — how the current release becomes the target release.
 *     Carries NO facet swaps and NO hash changes: the delta is DERIVED on-chain from the
 *     `(fromRelease, newRelease)` pair at initialization. What is authored: version edge,
 *     upgrade engine, schedule, and the typed `L2UpgradePlan`.
 *   - `CoreRegistry.CoreRegistryManifest` — the ecosystem inventory: a fixed-length row array
 *     indexed by `L1EcosystemContract`, source-checked rows in the participating slots, zero
 *     `implNew` in the explicitly-not-upgraded ones.
 *
 * Enum identifiers and inventory slot names in the manifest are NAMES; enum values are parsed
 * from the canonical Solidity sources at runtime (never hardcoded), so upstream reordering or
 * renaming cannot silently skew the encoding.
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
  // Strip comments before locating the body: a `}` or `,` inside an explanatory comment is
  // neither the enum's closing brace nor a member separator. Matching first and stripping the
  // captured body afterwards truncates the enum at the first brace a comment happens to contain
  // and silently drops every member below it, shifting the inventory length.
  const source = fs
    .readFileSync(path.join(l1ContractsDir, relSourcePath), "utf-8")
    .replace(/\/\/.*$/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "");
  const match = source.match(new RegExp(`enum\\s+${enumName}\\s*\\{([^}]*)\\}`));
  if (!match) {
    throw new Error(`enum ${enumName} not found in ${relSourcePath}`);
  }
  const members = match[1]
    .split(",")
    .map((m) => m.trim())
    .filter((m) => m.length > 0);
  return Object.fromEntries(members.map((m, i) => [m, i]));
}

const CONTRACT_IDENTIFIERS_SOL = "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

function enumValue(map: Record<string, number>, name: string, enumName: string): number {
  const value = map[name];
  if (value === undefined) {
    throw new Error(`unknown ${enumName} member "${name}"`);
  }
  return value;
}

/** One `ProxyUpgradeRow` in the shape ethers encodes against the contract ABI. */
interface ProxyUpgradeRowArg {
  proxy: string;
  expectedOldImpl: string;
  implNew: string;
  callInitializeUpgrade: boolean;
  /** The row's own ProxyAdmin; the zero address means the applying executor's bound admin. */
  admin: string;
}

/** An inert inventory slot: the explicit "not upgraded" statement. */
function zeroProxyUpgradeRow(): ProxyUpgradeRowArg {
  return {
    proxy: ethers.constants.AddressZero,
    expectedOldImpl: ethers.constants.AddressZero,
    implNew: ethers.constants.AddressZero,
    callInitializeUpgrade: false,
    admin: ethers.constants.AddressZero,
  };
}

/**
 * Builds a fixed-length proxy-upgrade inventory array from rows keyed by SLOT NAME. Slot names
 * are the members of the canonical contract enum (`L1EcosystemContract` for the ecosystem
 * domain, `CTMContract` for the CTM domain — the same enum that identifies the contract for
 * deployment), parsed from the Solidity source; a row keyed by anything else refuses to encode,
 * and every unnamed slot encodes as the explicit zero ("not upgraded") row.
 */
export function proxyUpgradeSlots(enumName: string, rows: Record<string, ProxyUpgradeRowArg>): ProxyUpgradeRowArg[] {
  const members = parseSolidityEnum(CONTRACT_IDENTIFIERS_SOL, enumName);
  const slots = Array.from({ length: Object.keys(members).length }, () => zeroProxyUpgradeRow());
  for (const [name, row] of Object.entries(rows ?? {})) {
    slots[enumValue(members, name, enumName)] = row;
  }
  return slots;
}

/**
 * Builds the release's fixed-length L2 bytecode table (`ReleaseManifest.l2BytecodeInfos`) from
 * implementation rows keyed by `L2EcosystemContract` MEMBER NAME; every unnamed slot encodes as
 * the explicit empty row ("not part of this release's force-deployed set").
 */
export function l2BytecodeInfoSlots(rows: Record<string, string>): string[] {
  const members = parseSolidityEnum(CONTRACT_IDENTIFIERS_SOL, "L2EcosystemContract");
  const slots = Array.from({ length: Object.keys(members).length }, () => "0x");
  for (const [name, info] of Object.entries(rows ?? {})) {
    slots[enumValue(members, name, "L2EcosystemContract")] = info;
  }
  return slots;
}

// Loose manifest typing: the JSON schema is owned by the emit side of the upgrade runner.
/* eslint-disable @typescript-eslint/no-explicit-any */

/** `CoreRegistry.CoreRegistryManifest` initialize argument from the manifest JSON. */
export function coreInitArgs(manifest: any): any {
  // The JSON keys under `core.contracts` ARE `L1EcosystemContract` member names — one naming
  // scheme for deployment and upgrades alike, with unknown keys refused at encode time.
  const entries: Array<[string, any]> = Object.entries(manifest.core.contracts);
  const rows = Object.fromEntries(
    entries.map(([name, e]) => [
      name,
      {
        proxy: e.proxy,
        expectedOldImpl: e.expectedOldImpl ?? ethers.constants.AddressZero,
        implNew: e.implNew ?? ethers.constants.AddressZero,
        callInitializeUpgrade: e.callInitializeUpgrade ?? false,
        admin: e.admin ?? ethers.constants.AddressZero,
      },
    ])
  );

  return { proxyUpgrades: proxyUpgradeSlots("L1EcosystemContract", rows) };
}

/** `CTMRelease.ReleaseManifest` initialize argument from one `manifest.ctms[]` entry. */
export function releaseInitArgs(ctm: any): any {
  const release = ctm.release;

  // Routing is read from each facet's own self-description, never stored.
  const genesisFacets = release.genesisFacets.map((f: any) => ({
    facet: f.address,
    isFreezable: f.isFreezable,
  }));

  // The one shell every table row sits behind is a manifest statement like the rows, so a
  // manifest written before the field existed refuses to encode rather than defaulting.
  if (typeof release.l2SystemProxyBytecodeInfo !== "string") {
    throw new Error("release.l2SystemProxyBytecodeInfo missing from the registry manifest");
  }

  return {
    diamondInit: release.diamondInit.address,
    verifier: release.verifier.address,
    genesisUpgrade: release.genesis.genesisUpgrade.address,
    genesisFacets,
    // `ReleaseGenesisData`.
    genesis: {
      fixedForceDeploymentsData: release.fixedForceDeploymentsData,
      genesisBatchHash: release.genesis.batchHash,
      genesisBatchCommitment: release.genesis.batchCommitment,
      genesisIndexRepeatedStorageChanges: release.genesis.indexRepeatedStorageChanges,
    },
    l2BytecodeInfos: l2BytecodeInfoSlots(release.l2BytecodeInfos ?? {}),
    l2SystemProxyBytecodeInfo: release.l2SystemProxyBytecodeInfo,
  };
}

/**
 * `CTMTransition.TransitionManifest` initialize argument from one `manifest.ctms[]` entry.
 * `newRelease` is the just-deployed `CTMRelease` address — passed in by the runner rather than
 * read from the JSON, since the release must be deployed first anyway (transition
 * initialization validates it and derives the facet/hash delta from the release pair).
 */
export function transitionInitArgs(manifest: any, ctm: any, newRelease: string, delegateComposer: string): any {
  // Release provenance is not a manifest field: `setCurrentRelease` runs the release's own
  // `validate()` and genesis-parameter checks, and the reviewed object's address is re-derived
  // off-chain from its creation code by `protocol-ops ecosystem verify-bootstrap`.
  const transition = ctm.transition;

  // The manifest authors bytecode infos only: the object constructs the Unsafe deployments, the
  // delegate target and the factory dependencies from them (plus the table-derived set) at
  // initialization. A manifest JSON still carrying the pre-construction `deployments` /
  // `delegateTo` / `factoryDepHashes` keys predates that and must be re-emitted.
  if (typeof transition.l2Plan?.delegateBytecodeInfo !== "string") {
    throw new Error(
      "manifest l2Plan predates plan construction (expected `delegateBytecodeInfo`); regenerate with REGEN_REGISTRIES=1"
    );
  }

  return {
    // The registry-driven hop departs from the BOOTSTRAP edge's target version (the bootstrap
    // crossed manifest.oldVersion -> manifest.bootstrapVersion first).
    oldProtocolVersion: packSemVer(manifest.bootstrapVersion),
    newProtocolVersion: packSemVer(manifest.newVersion),
    fromRelease: transition.fromRelease,
    newRelease,
    upgradeEngine: transition.upgradeEngine.address,
    oldProtocolVersionDeadline: ethers.BigNumber.from(transition.oldProtocolVersionDeadline),
    upgradeTimestamp: transition.upgradeTimestamp,
    l2Plan: {
      delegateBytecodeInfo: transition.l2Plan.delegateBytecodeInfo,
      extraBytecodeInfos: transition.l2Plan.extraBytecodeInfos ?? [],
      // Version-specific CODE defines the delegate calldata; the harness names a fixed no-op
      // composer deployed alongside the objects (see the runner).
      delegateComposer,
    },
  };
}

/**
 * `EcosystemUpgradeOperation.OperationManifest` initialize argument. The CTM-domain inventory
 * (indexed by `CTMContract`) and the stage-1 timer are the OPERATION's, not the transition's; the
 * local hop upgrades chain state only, so the manifest carries no infrastructure slots and every
 * one encodes as the explicit zero ("not upgraded") row.
 */
export function operationInitArgs(ctm: any, coreRegistry: string, transition: string, timer: string): any {
  return {
    coreRegistry,
    ctmInfrastructure: proxyUpgradeSlots("CTMContract", ctm.transition?.proxyUpgrades ?? {}),
    transition,
    timer,
  };
}
