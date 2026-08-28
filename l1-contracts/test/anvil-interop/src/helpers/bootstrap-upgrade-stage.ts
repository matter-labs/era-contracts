/**
 * Bootstrap stage of the registry-driven upgrade test (the "V33 -> V34" edge).
 *
 * Models the ONE-TIME entry of a pre-registry ecosystem into the registry-driven model through
 * `RegistryBootstrapMigration` (see the Bootstrap section of docs/registry-driven-upgrades.md),
 * in front of the generic registry-driven hop the runner already performs ("V34 -> V35"):
 *
 *   1. The target chains get the LEGACY cut-taking upgrade entrypoint installed
 *      (`LegacyTestAdminFacet`): the chain states are built from CURRENT sources, whose Admin
 *      facet reads its cut from the CTM — but production chains crossing the bootstrap edge run
 *      pre-v34 facets that are HANDED the cut and verify it against `upgradeCutHash`. The
 *      legacy facet reproduces that entrypoint faithfully; the bootstrap cut itself removes it
 *      again, so the harness patch cancels itself out and the post-bootstrap chain state matches
 *      the release the CTM pins.
 *   2. Governance (impersonated) hands the CTM and the ecosystem ProxyAdmin to the deployed
 *      `RegistryBootstrapMigration`, whose manifest pins: the CTM implementation swap (a REAL
 *      source-checked proxy row), the legacy upgrade cut + its engine pin, the version edge and
 *      the old-version deadline, the release anchor, and the two bound executors.
 *   3. `migrate()` runs the whole edge in one transaction: impl swap, legacy
 *      `setNewVersionUpgrade` commit (writing the deprecated `upgradeCutHash` — the ONLY writer
 *      left), release re-pin, and the authority handover to the executors.
 *   4. Each chain's admin crosses the edge through the legacy 3-arg `upgradeChainFromVersion`,
 *      handing the committed cut — verified against `upgradeCutHash` exactly like production
 *      pre-v34 chains do.
 *
 * After this stage the WHOLE CTM domain — the CTM and its own ProxyAdmin — is owned by
 * `CTMUpgradeExecutor`, and every later upgrade is registry-driven — which is exactly what the
 * runner's next stage exercises. (Ecosystem singletons stay under the separate ecosystem
 * ProxyAdmin / `EcosystemUpgradeExecutor`.)
 */

import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import { impersonateAndRun } from "../core/utils";

/* eslint-disable @typescript-eslint/no-explicit-any */

const DEFAULT_GAS_LIMIT = 10_000_000;

// Diamond.Action enum (contracts/state-transition/libraries/Diamond.sol).
const DIAMOND_ACTION_ADD = 0;
const DIAMOND_ACTION_REMOVE = 2;

export type BootstrapPieces = {
  legacyAdminFacet: string;
  bootstrapEngine: string;
  ctmImplNew: string;
};

type Assert = {
  assertEq(actual: unknown, expected: unknown, message: string): void;
  assertTrue(condition: boolean, message: string): void;
};

type SendAndCheck = (
  provider: ethers.providers.JsonRpcProvider,
  txPromise: Promise<ethers.providers.TransactionResponse>,
  label: string
) => Promise<ethers.providers.TransactionReceipt>;

export function legacyUpgradeSelector(): string {
  return new ethers.utils.Interface(getAbi("LegacyTestAdminFacet")).getSighash("upgradeChainFromVersion");
}

/** The manifest's `bootstrap` section (emit mode). */
export async function buildBootstrapSection(
  l1Provider: ethers.providers.JsonRpcProvider,
  pieces: BootstrapPieces,
  ctmProxy: string,
  ctmImplOld: string,
  oldVersionDeadline: string
): Promise<Record<string, unknown>> {
  const codehash = async (addr: string) => ethers.utils.keccak256(await l1Provider.getCode(addr));
  return {
    // The pre-v34 cut-taking entrypoint the harness installs (and the bootstrap cut removes).
    legacyAdminFacet: pieces.legacyAdminFacet,
    // The legacy cut's init contract — pinned by `upgradeCutInitCodehash` in the migration.
    upgradeEngine: { address: pieces.bootstrapEngine, codehash: await codehash(pieces.bootstrapEngine) },
    // The canonical bootstrap operation: the CTM proxy's own implementation swap, as a
    // source-checked row.
    ctmImpl: {
      proxy: ctmProxy,
      expectedOldImpl: ctmImplOld,
      implNew: pieces.ctmImplNew,
      implNewCodehash: await codehash(pieces.ctmImplNew),
    },
    oldProtocolVersionDeadline: oldVersionDeadline,
  };
}

/** CONSUME-mode gate rows for the bootstrap section (same shape as the runner's other checks). */
export function bootstrapManifestChecks(
  manifest: any,
  pieces: BootstrapPieces,
  ctmProxy: string,
  ctmImplOld: string
): Array<[string, unknown, unknown]> {
  const b = manifest.bootstrap;
  return [
    ["bootstrap.legacyAdminFacet", b?.legacyAdminFacet, pieces.legacyAdminFacet],
    ["bootstrap.upgradeEngine.address", b?.upgradeEngine?.address, pieces.bootstrapEngine],
    ["bootstrap.ctmImpl.proxy", b?.ctmImpl?.proxy, ctmProxy],
    ["bootstrap.ctmImpl.expectedOldImpl", b?.ctmImpl?.expectedOldImpl, ctmImplOld],
    ["bootstrap.ctmImpl.implNew", b?.ctmImpl?.implNew, pieces.ctmImplNew],
  ];
}

/**
 * The legacy cut committed by the bootstrap, reconstructed deterministically from the manifest
 * (both modes build it the same way — it is never stored raw in the JSON). It removes the
 * harness-installed legacy entrypoint and runs `DefaultUpgrade.upgrade` with a minimal
 * `ProposedUpgrade`: version bump only, no L2 transaction, no verifier/hash changes (an empty
 * L2 leg is skipped by `BaseZkSyncUpgrade`, and zero verifier/hash values mean "keep").
 */
export function buildBootstrapCut(manifest: any, packSemVer: (v: string) => bigint): any {
  const emptyL2Tx = {
    txType: 0,
    from: 0,
    to: 0,
    gasLimit: 0,
    gasPerPubdataByteLimit: 0,
    maxFeePerGas: 0,
    maxPriorityFeePerGas: 0,
    paymaster: 0,
    nonce: 0,
    value: 0,
    reserved: [0, 0, 0, 0],
    data: "0x",
    signature: "0x",
    factoryDeps: [],
    paymasterInput: "0x",
    reservedDynamic: "0x",
  };
  const proposedUpgrade = {
    l2ProtocolUpgradeTx: emptyL2Tx,
    bootloaderHash: ethers.constants.HashZero,
    defaultAccountHash: ethers.constants.HashZero,
    evmEmulatorHash: ethers.constants.HashZero,
    verifier: ethers.constants.AddressZero,
    verifierParams: {
      recursionNodeLevelVkHash: ethers.constants.HashZero,
      recursionLeafLevelVkHash: ethers.constants.HashZero,
      recursionCircuitsSetVksHash: ethers.constants.HashZero,
    },
    l1ContractsUpgradeCalldata: "0x",
    postUpgradeCalldata: "0x",
    upgradeTimestamp: 0,
    newProtocolVersion: packSemVer(manifest.bootstrapVersion),
  };
  const engineIface = new ethers.utils.Interface(getAbi("DefaultUpgrade"));
  return {
    facetCuts: [
      {
        facet: ethers.constants.AddressZero,
        action: DIAMOND_ACTION_REMOVE,
        isFreezable: false,
        selectors: [legacyUpgradeSelector()],
      },
    ],
    initAddress: manifest.bootstrap.upgradeEngine.address,
    initCalldata: engineIface.encodeFunctionData("upgrade", [proposedUpgrade]),
  };
}

/** `RegistryBootstrapMigration.BootstrapManifest` constructor argument. */
export async function bootstrapInitArgs(
  l1Provider: ethers.providers.JsonRpcProvider,
  manifest: any,
  packSemVer: (v: string) => bigint,
  params: {
    ctmProxy: string;
    proxyAdmin: string;
    releaseCodehash: string;
    currentRelease: string;
    ctmExecutor: string;
  }
): Promise<any> {
  const codehash = async (addr: string) => ethers.utils.keccak256(await l1Provider.getCode(addr));
  return {
    ctm: params.ctmProxy,
    expectedProtocolVersion: packSemVer(manifest.oldVersion),
    ctmProxyAdmin: params.proxyAdmin,
    proxyRows: [
      {
        proxy: manifest.bootstrap.ctmImpl.proxy,
        expectedOldImpl: manifest.bootstrap.ctmImpl.expectedOldImpl,
        implNew: {
          addr: manifest.bootstrap.ctmImpl.implNew,
          codehash: manifest.bootstrap.ctmImpl.implNewCodehash,
        },
        initCalldata: "0x",
      },
    ],
    currentRelease: { addr: params.currentRelease, codehash: params.releaseCodehash },
    newProtocolVersion: packSemVer(manifest.bootstrapVersion),
    oldProtocolVersionDeadline: ethers.BigNumber.from(manifest.bootstrap.oldProtocolVersionDeadline),
    upgradeCut: buildBootstrapCut(manifest, packSemVer),
    upgradeCutInitCodehash: manifest.bootstrap.upgradeEngine.codehash,
    // The executor is deployed by this run (regular build), so its codehash is read live
    // rather than committed — the manifest pins only cross-machine-stable values.
    ctmExecutor: { addr: params.ctmExecutor, codehash: await codehash(params.ctmExecutor) },
  };
}

/**
 * Install the legacy cut-taking entrypoint on each target chain (harness patch #1 — see module
 * docs). Runs through the CTM owner's `executeUpgrade`, the production path for owner-forced
 * cuts, BEFORE the CTM is handed to the migration.
 */
export async function installLegacyFacet(
  l1Provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string,
  legacyFacet: string,
  chains: Array<{ chainId: number; diamondProxy: string }>,
  sendAndCheck: SendAndCheck
): Promise<void> {
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), l1Provider);
  const ownable = new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), l1Provider);
  const owner: string = await ownable.owner();
  const addCut = {
    facetCuts: [
      {
        facet: legacyFacet,
        action: DIAMOND_ACTION_ADD,
        isFreezable: false,
        selectors: [legacyUpgradeSelector()],
      },
    ],
    initAddress: ethers.constants.AddressZero,
    initCalldata: "0x",
  };
  await impersonateAndRun(l1Provider, owner, async (signer) => {
    for (const chain of chains) {
      await sendAndCheck(
        l1Provider,
        ctm.connect(signer).executeUpgrade(chain.chainId, addCut, { gasLimit: DEFAULT_GAS_LIMIT }),
        `install legacy facet on chain ${chain.chainId}`
      );
    }
  });
  console.log(`  ✓ legacy cut-taking entrypoint installed on ${chains.length} chain(s)`);
}

/** Hand CTM (2-step nomination) + ProxyAdmin (1-step) to the migration, impersonating governance. */
export async function handAuthorityToMigration(
  l1Provider: ethers.providers.JsonRpcProvider,
  migration: string,
  ctmAddr: string,
  proxyAdminAddr: string,
  sendAndCheck: SendAndCheck
): Promise<void> {
  const ctmOwnable = new ethers.Contract(ctmAddr, getAbi("Ownable2Step"), l1Provider);
  const ctmOwner: string = await ctmOwnable.owner();
  await impersonateAndRun(l1Provider, ctmOwner, async (signer) => {
    await sendAndCheck(
      l1Provider,
      ctmOwnable.connect(signer).transferOwnership(migration, { gasLimit: DEFAULT_GAS_LIMIT }),
      "CTM transferOwnership(migration)"
    );
  });
  const proxyAdmin = new ethers.Contract(proxyAdminAddr, getAbi("ProxyAdmin"), l1Provider);
  const proxyAdminOwner: string = await proxyAdmin.owner();
  await impersonateAndRun(l1Provider, proxyAdminOwner, async (signer) => {
    await sendAndCheck(
      l1Provider,
      proxyAdmin.connect(signer).transferOwnership(migration, { gasLimit: DEFAULT_GAS_LIMIT }),
      "ProxyAdmin transferOwnership(migration)"
    );
  });
  console.log("  ✓ CTM nominated + ProxyAdmin owned by the bootstrap migration");
}

/**
 * Cross the bootstrap edge on each chain through the legacy handed-cut entrypoint, as the
 * chain's own admin — the production shape for pre-v34 chains.
 */
export async function crossBootstrapEdgeOnChains(
  l1Provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>,
  oldVersion: ethers.BigNumber,
  bootstrapCut: any,
  sendAndCheck: SendAndCheck
): Promise<void> {
  // The facet's compiled ABI (named tuple components) — a human-readable fragment cannot
  // object-encode the cut struct.
  const legacyIface = new ethers.utils.Interface(getAbi("LegacyTestAdminFacet"));
  for (const chain of chains) {
    const getters = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
    const admin: string = await getters.getAdmin();
    const data = legacyIface.encodeFunctionData("upgradeChainFromVersion", [
      chain.diamondProxy,
      oldVersion,
      bootstrapCut,
    ]);
    await impersonateAndRun(l1Provider, admin, async (signer) => {
      await sendAndCheck(
        l1Provider,
        signer.sendTransaction({ to: chain.diamondProxy, data, gasLimit: DEFAULT_GAS_LIMIT }),
        `chain ${chain.chainId}: legacy upgradeChainFromVersion(handed cut)`
      );
    });
    console.log(`  ✓ chain ${chain.chainId} crossed the bootstrap edge (handed cut)`);
  }
}

/** Post-bootstrap assertions (L1 side). */
export async function assertBootstrapEndState(
  l1Provider: ethers.providers.JsonRpcProvider,
  a: Assert,
  params: {
    ctmAddr: string;
    migration: string;
    oldVersion: ethers.BigNumber;
    midVersion: ethers.BigNumber;
    bootstrapCut: any;
    ctmImplNew: string;
    ctmExecutor: string;
    ecoExecutor: string;
    proxyAdminAddr: string;
    chains: Array<{ chainId: number; diamondProxy: string }>;
    deadline: ethers.BigNumber;
  }
): Promise<void> {
  const ctm = new ethers.Contract(params.ctmAddr, getAbi("IChainTypeManager"), l1Provider);
  const cutTypes = [
    "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)",
  ];
  const cutHash = ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(cutTypes, [params.bootstrapCut]));

  a.assertEq(
    (await ctm.protocolVersion()).toString(),
    params.midVersion.toString(),
    "CTM protocol version bumped by the bootstrap edge"
  );
  // The legacy cut-taking commit is the ONE writer of the deprecated hash; no transition exists
  // for this edge, and the deadline is served from the legacy storage that same path wrote.
  a.assertEq(await ctm.upgradeCutHash(params.oldVersion), cutHash, "bootstrap edge committed the legacy cut hash");
  a.assertEq(
    await ctm.upgradeTransition(params.oldVersion),
    ethers.constants.AddressZero,
    "no transition exists for the bootstrap edge"
  );
  a.assertEq(
    (await ctm.protocolVersionDeadline(params.oldVersion)).toString(),
    params.deadline.toString(),
    "old-version deadline served from the legacy storage the bootstrap wrote"
  );

  const EIP1967_IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
  const implSlot = await l1Provider.getStorageAt(params.ctmAddr, EIP1967_IMPL_SLOT);
  a.assertEq(
    ethers.utils.getAddress("0x" + implSlot.slice(26)),
    params.ctmImplNew,
    "CTM proxy re-pointed to the fresh implementation by the bootstrap"
  );

  const migration = new ethers.Contract(params.migration, getAbi("RegistryBootstrapMigration"), l1Provider);
  a.assertTrue(await migration.executed(), "bootstrap migration marked executed");
  let replayReverted = false;
  try {
    await migration.callStatic.migrate();
  } catch {
    replayReverted = true;
  }
  a.assertTrue(replayReverted, "bootstrap migration replay reverts (one-shot edge)");

  const ctmOwnable = new ethers.Contract(params.ctmAddr, getAbi("Ownable2Step"), l1Provider);
  a.assertEq(await ctmOwnable.owner(), params.ctmExecutor, "CTM owned by CTMUpgradeExecutor after the bootstrap");
  const proxyAdmin = new ethers.Contract(params.proxyAdminAddr, getAbi("ProxyAdmin"), l1Provider);
  a.assertEq(
    await proxyAdmin.owner(),
    params.ecoExecutor,
    "CTM-domain ProxyAdmin owned by CTMUpgradeExecutor after the bootstrap"
  );

  for (const chain of params.chains) {
    const diamond = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), l1Provider);
    a.assertEq(
      (await diamond.getProtocolVersion()).toString(),
      params.midVersion.toString(),
      `chain ${chain.chainId}: bumped to the bootstrap version`
    );
    a.assertEq(
      await diamond.facetAddress(legacyUpgradeSelector()),
      ethers.constants.AddressZero,
      `chain ${chain.chainId}: legacy cut-taking entrypoint removed by the bootstrap cut`
    );
  }
}
