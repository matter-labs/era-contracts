/**
 * Bootstrap-edge helpers ("v34 -> v35") for the pipeline runner, which drives the one-time entry
 * into the registry-driven model through protocol-ops against the frozen previous-release states
 * (see the Bootstrap section of docs/registry-driven-upgrades.md):
 *
 * - `installLegacyFacet`: for a fixture whose chains already READ their cut from the CTM, installs
 *   the pre-v35 cut-taking entrypoint (`LegacyTestAdminFacet`) production pre-v35 chains run; the
 *   bootstrap cut removes it again.
 * - `crossBootstrapEdgeOnChains`: each chain's admin crosses the edge through the legacy 3-arg
 *   `upgradeChainFromVersion`, handing the committed cut.
 * - `assertBootstrapBundle`: the merged prepare's governance bundle is the one
 *   `RegistryBootstrapSequence.actions()` derives, ending in the completion check.
 * - `assertBootstrapCompleted`: the completion check re-run read-only after the governance replay.
 * - `assertServerNotifierState`: the ServerNotifier's custody (also used by the recurring runner).
 */

import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import { impersonateAndRun } from "../core/utils";
import type { ExpectedCall, MergedGovernanceOutput } from "./governance-bundle";
import { assertBundleIs, governanceCallsOf } from "./governance-bundle";
import { proxyUpgradeSlotIndex } from "./registry-manifest";
import { readProxyAdmin, readProxyImplementation } from "./upgrade-test-utils";

/* eslint-disable @typescript-eslint/no-explicit-any */

const DEFAULT_GAS_LIMIT = 10_000_000;

// Diamond.Action enum (contracts/state-transition/libraries/Diamond.sol).
const DIAMOND_ACTION_ADD = 0;

type SendAndCheck = (
  provider: ethers.providers.JsonRpcProvider,
  txPromise: Promise<ethers.providers.TransactionResponse>,
  label: string
) => Promise<ethers.providers.TransactionReceipt>;

function legacyUpgradeSelector(): string {
  return new ethers.utils.Interface(getAbi("LegacyTestAdminFacet")).getSighash("upgradeChainFromVersion");
}

/**
 * Install the legacy cut-taking entrypoint on each target chain (a harness patch — see module
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

/**
 * The bootstrap bundle `RegistryBootstrapSequence.actions()` derives, re-derived from the
 * migration's manifest and live state so the prepare output is checked against an independent
 * derivation. Read after the prepare: whether the bundle opens with the ServerNotifier accept
 * depends on the notifier's live owner.
 * @param coreTransition The core transition the core prepare pinned (the sequence's
 *        `CORE_TRANSITION`, which the migration's manifest does not name).
 */
export async function deriveBootstrapBundle(
  l1Provider: ethers.providers.JsonRpcProvider,
  migrationAddr: string,
  coreTransition: string
): Promise<ExpectedCall[]> {
  const migration = new ethers.Contract(migrationAddr, getAbi("RegistryBootstrapMigration"), l1Provider);
  const m = await migration.getManifest();
  const coreExecutor = new ethers.Contract(m.coreExecutor, getAbi("CoreUpgradeExecutor"), l1Provider);
  const notifier: string = m.ctmProxyUpgrades[proxyUpgradeSlotIndex("CTMContract", "ServerNotifier")].proxy;
  const notifierOwner: string = await new ethers.Contract(notifier, getAbi("Ownable2Step"), l1Provider).owner();
  const ownable = new ethers.utils.Interface(getAbi("Ownable2Step"));
  const proxyAdmin = new ethers.utils.Interface(getAbi("ProxyAdmin"));
  const ctmExecutor = new ethers.utils.Interface(getAbi("CTMUpgradeExecutor"));
  const coordinator = new ethers.utils.Interface(getAbi("EcosystemUpgradeExecutor"));

  const bundle: ExpectedCall[] = [];
  if (notifierOwner.toLowerCase() !== m.ctmExecutor.toLowerCase()) {
    const accept = { target: notifier, value: 0, data: ownable.encodeFunctionData("acceptOwnership") };
    bundle.push({
      label: "ctmExecutor.forward([ServerNotifier.acceptOwnership()])",
      target: m.ctmExecutor,
      data: ctmExecutor.encodeFunctionData("forward", [[accept]]),
    });
  }
  bundle.push(
    {
      label: "coreExecutor.setCoordinator(coordinator)",
      target: m.coreExecutor,
      data: coreExecutor.interface.encodeFunctionData("setCoordinator", [m.coordinator]),
    },
    {
      label: "coordinator.setCTMExecutor(ctmExecutor)",
      target: m.coordinator,
      data: coordinator.encodeFunctionData("setCTMExecutor", [m.ctmExecutor]),
    },
    {
      label: "ecosystem ProxyAdmin.transferOwnership(coreExecutor)",
      target: await coreExecutor.PROXY_ADMIN(),
      data: proxyAdmin.encodeFunctionData("transferOwnership", [m.coreExecutor]),
    },
    {
      label: "coreExecutor.applyL1Upgrade(coreTransition)",
      target: m.coreExecutor,
      data: coreExecutor.interface.encodeFunctionData("applyL1Upgrade", [coreTransition]),
    },
    {
      label: "CTM.transferOwnership(migration)",
      target: m.ctm,
      data: ownable.encodeFunctionData("transferOwnership", [migrationAddr]),
    },
    {
      label: "CTM-domain ProxyAdmin.transferOwnership(migration)",
      target: m.ctmProxyAdmin,
      data: proxyAdmin.encodeFunctionData("transferOwnership", [migrationAddr]),
    },
    {
      label: "migration.migrate()",
      target: migrationAddr,
      data: migration.interface.encodeFunctionData("migrate"),
    },
    {
      label: "migration.validateApplied()",
      target: migrationAddr,
      data: migration.interface.encodeFunctionData("validateApplied"),
    }
  );
  return bundle;
}

/**
 * Throws unless the merged prepare output's governance bundle is exactly the derived bootstrap
 * bundle ({@link deriveBootstrapBundle}) — in particular, that it closes with the migration's
 * `validateApplied()`.
 */
export async function assertBootstrapBundle(
  l1Provider: ethers.providers.JsonRpcProvider,
  merged: MergedGovernanceOutput,
  migrationAddr: string,
  coreTransition: string
): Promise<void> {
  const bundle = governanceCallsOf(merged);
  const closing = bundle[bundle.length - 1];
  const validateApplied = new ethers.utils.Interface(getAbi("RegistryBootstrapMigration")).encodeFunctionData(
    "validateApplied"
  );
  if (
    !closing ||
    closing.target.toLowerCase() !== migrationAddr.toLowerCase() ||
    closing.data.toLowerCase() !== validateApplied.toLowerCase()
  ) {
    throw new Error(`the bootstrap bundle does not close with ${migrationAddr}.validateApplied()`);
  }
  const expected = await deriveBootstrapBundle(l1Provider, migrationAddr, coreTransition);
  assertBundleIs(bundle, expected, "the bootstrap governance bundle");
  console.log(`  ✓ the governance bundle is the derived bootstrap sequence (${bundle.length} calls)`);
}

/**
 * Re-runs the edge's completion check, `RegistryBootstrapMigration.validateApplied()`, read-only
 * after the governance replay. The bundle's last call already enforces it, but the harness executes
 * the Safe bundles protocol-ops builds from the merged TOML, not the TOML whose shape it asserted;
 * this checks the state those left. A revert is rethrown with the decoded error.
 */
export async function assertBootstrapCompleted(
  l1Provider: ethers.providers.JsonRpcProvider,
  migrationAddr: string
): Promise<void> {
  const migration = new ethers.Contract(migrationAddr, getAbi("RegistryBootstrapMigration"), l1Provider);
  try {
    await migration.validateApplied();
  } catch (error) {
    const e = error as { errorName?: string; errorArgs?: unknown[]; message?: string };
    const reason = e.errorName ? `${e.errorName}(${(e.errorArgs ?? []).join(", ")})` : e.message;
    throw new Error(`RegistryBootstrapMigration ${migrationAddr}: validateApplied() reverted: ${reason}`);
  }
  console.log("  ✓ RegistryBootstrapMigration.validateApplied() holds");
}

/** The CTM's ServerNotifier, read live. */
export type ServerNotifierState = {
  notifier: string;
  admin: string;
  implementation: string;
  owner: string;
  pendingOwner: string;
  chainTypeManager: string;
};

export async function readServerNotifierState(
  l1Provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string
): Promise<ServerNotifierState> {
  const ctm = new ethers.Contract(ctmAddr, getAbi("IChainTypeManager"), l1Provider);
  const notifierAddr: string = await ctm.serverNotifierAddress();
  const notifier = new ethers.Contract(notifierAddr, getAbi("ServerNotifier"), l1Provider);
  return {
    notifier: notifierAddr,
    admin: await readProxyAdmin(l1Provider, notifierAddr),
    implementation: await readProxyImplementation(l1Provider, notifierAddr),
    owner: await notifier.owner(),
    pendingOwner: await notifier.pendingOwner(),
    chainTypeManager: await notifier.chainTypeManager(),
  };
}

/** Throws unless every field `expected` names matches the live notifier; returns the live state. */
export async function assertServerNotifierState(
  l1Provider: ethers.providers.JsonRpcProvider,
  ctmAddr: string,
  expected: Partial<Omit<ServerNotifierState, "notifier">>,
  label: string
): Promise<ServerNotifierState> {
  const state = await readServerNotifierState(l1Provider, ctmAddr);
  const fields = Object.entries(expected) as Array<[keyof Omit<ServerNotifierState, "notifier">, string]>;
  const mismatches = fields
    .filter(([field, value]) => state[field].toLowerCase() !== value.toLowerCase())
    .map(([field, value]) => `  ${field}: live ${state[field]}, expected ${value}`);
  if (mismatches.length > 0) {
    throw new Error(`ServerNotifier ${state.notifier}: ${label}\n${mismatches.join("\n")}`);
  }
  console.log(`  ✓ ServerNotifier ${label} (${fields.map(([field]) => field).join(", ")})`);
  return state;
}

/**
 * Cross the bootstrap edge on each chain through the legacy handed-cut entrypoint, as the
 * chain's own admin — the production shape for pre-v35 chains.
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
