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
 *   - `CoreRegistry.CoreRegistryManifest` — source-checked ecosystem rows
 *     (`expectedOldImpl -> implNew` with inline pins).
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
  // Row identity is the proxy ADDRESS; the manifest's contract names are human labels only.
  const entries: Array<[string, any]> = Object.entries(manifest.core.contracts);
  const contractRows = entries.map(([, e]) => ({
    proxy: e.proxy,
    expectedOldImpl: e.expectedOldImpl ?? ethers.constants.AddressZero,
    implNew: {
      addr: e.implNew ?? ethers.constants.AddressZero,
      codehash: e.implNewCodehash ?? ethers.constants.HashZero,
    },
  }));

  return { contractRows };
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
