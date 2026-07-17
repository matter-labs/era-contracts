/**
 * Registry manifest -> initialize() arguments.
 *
 * The storage-backed, write-once upgrade objects (`CTMRelease` / `CTMTransition` /
 * `CoreRegistry`, contracts/upgrades/registry) are fixed, audited-once implementations
 * initialized exactly once with a full manifest struct. This module translates the committed
 * manifest JSON (scripts/registry-manifests/*.json — the reviewable per-upgrade artifact) into
 * the `initialize()` argument objects ethers encodes against the contract ABIs:
 *
 *   - `CTMRelease.ReleaseManifest`     — what a chain at the target release IS (facets,
 *     DiamondInit, base-system hashes, force-deployments, genesis params). Version-independent.
 *   - `CTMTransition.TransitionManifest` — how the current release becomes the target release
 *     (facet swaps, L2 leg, schedule, verifier, `fromRelease -> newRelease` and
 *     `oldProtocolVersion -> newProtocolVersion` edges).
 *   - `CoreRegistry.CoreRegistryManifest` — the ecosystem-wide proxy -> new-implementation rows.
 *
 * Enum identifiers in the manifest are NAMES; their numeric values are parsed from the
 * canonical Solidity sources at runtime (never hardcoded), so enum reordering upstream cannot
 * silently skew the encoding. Facet rows need no enum at all — `GenesisFacet` and
 * `UpgradeFacetSwap` are address-based; manifest facet names are human labels only.
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
  const ecosystemContract = parseSolidityEnum(IDENTIFIERS_SOL, "L1EcosystemContract");

  const entries: Array<[string, any]> = Object.entries(manifest.core.contracts);
  const contractRows = entries.map(([name, e]) => ({
    key: enumValue(ecosystemContract, name, "L1EcosystemContract"),
    proxy: e.proxy,
    implNew: e.implNew ?? ethers.constants.AddressZero,
  }));
  const codehashPins = entries
    .filter(([, e]) => e.implNew && e.implNewCodehash)
    .map(([, e]) => ({ target: e.implNew, expectedCodehash: e.implNewCodehash }));

  return {
    proxyAdmin: manifest.core.proxyAdmin,
    contractRows,
    codehashPins,
  };
}

/** `CTMRelease.ReleaseManifest` initialize argument from one `manifest.ctms[]` entry. */
export function releaseInitArgs(ctm: any): any {
  const release = ctm.release;

  const genesisFacets = release.genesisFacets.map((f: any) => ({
    facet: f.address,
    isFreezable: f.isFreezable,
    selectors: f.selectors ?? [],
  }));

  // The release pins the codehash of everything it makes live on new chains: the complete
  // installed facet set and the DiamondInit.
  const codehashPins = [
    ...release.genesisFacets
      .filter((f: any) => f.codehash)
      .map((f: any) => ({ target: f.address, expectedCodehash: f.codehash })),
    { target: release.diamondInit.address, expectedCodehash: release.diamondInit.codehash },
  ];

  return {
    isZKsyncOS: ctm.isZKsyncOS,
    diamondInit: release.diamondInit.address,
    genesisFacets,
    bootloaderHash: release.baseSystemContracts.bootloader,
    defaultAccountHash: release.baseSystemContracts.defaultAccount,
    evmEmulatorHash: release.baseSystemContracts.evmEmulator,
    fixedForceDeploymentsData: release.fixedForceDeploymentsData,
    genesisUpgrade: release.genesis.genesisUpgrade,
    genesisBatchHash: release.genesis.batchHash,
    genesisBatchCommitment: release.genesis.batchCommitment,
    genesisIndexRepeatedStorageChanges: release.genesis.indexRepeatedStorageChanges,
    codehashPins,
  };
}

/**
 * `CTMTransition.TransitionManifest` initialize argument from one `manifest.ctms[]` entry.
 * `newRelease` is the just-deployed (nonce-deterministic) `CTMRelease` address — passed in by
 * the runner rather than read from the JSON, since the release must be deployed first anyway
 * (transition initialization validates it).
 */
export function transitionInitArgs(manifest: any, ctm: any, newRelease: string): any {
  const upgradeType = parseSolidityEnum(COMPLEX_UPGRADER_SOL, "ContractUpgradeType");
  const transition = ctm.transition;

  const facetTransitions = transition.facetSwaps.map((f: any) => ({
    oldFacet: f.oldFacet ?? ethers.constants.AddressZero,
    newFacet: f.newFacet,
    isFreezable: f.isFreezable,
    oldSelectors: f.oldSelectors ?? [],
    newSelectors: f.newSelectors ?? [],
  }));

  const l2Deployments = transition.l2.forceDeployments.map((d: any) => ({
    info: {
      upgradeType: enumValue(upgradeType, d.upgradeType, "ContractUpgradeType"),
      deployedBytecodeInfo: d.deployedBytecodeInfo,
      newAddress: d.newAddress,
    },
  }));

  // The transition pins what it (and only it) makes live: the verifier and the DefaultUpgrade
  // init contract. The new facets are pinned by the target release, which transition
  // initialization/validation checks transitively.
  const codehashPins = [
    { target: transition.verifier.address, expectedCodehash: transition.verifier.codehash },
    { target: transition.defaultUpgrade.address, expectedCodehash: transition.defaultUpgrade.codehash },
  ];

  return {
    ctmProxy: ctm.ctmProxy,
    oldProtocolVersion: packSemVer(manifest.oldVersion),
    newProtocolVersion: packSemVer(manifest.newVersion),
    verifier: transition.verifier.address,
    fromRelease: transition.fromRelease,
    newRelease,
    defaultUpgrade: transition.defaultUpgrade.address,
    oldProtocolVersionDeadline: ethers.BigNumber.from(transition.oldProtocolVersionDeadline),
    upgradeTimestamp: transition.upgradeTimestamp,
    facetTransitions,
    l2Deployments,
    l2UpgradeDelegateTo: transition.l2.delegateTo,
    l2UpgradeDelegateCalldata: transition.l2.delegateCalldata,
    factoryDepHashes: transition.l2.factoryDepHashes.map((h: string) => ethers.BigNumber.from(h)),
    bootloaderHash: transition.l2.baseSystemContractChanges.bootloader,
    defaultAccountHash: transition.l2.baseSystemContractChanges.defaultAccount,
    evmEmulatorHash: transition.l2.baseSystemContractChanges.evmEmulator,
    codehashPins,
  };
}
