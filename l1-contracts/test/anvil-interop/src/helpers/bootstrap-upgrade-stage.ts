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
 * - `assertBootstrapCompleted`: the edge's completion check, run as its own call after stage 2.
 * - `assertServerNotifierState`: the ServerNotifier's custody (also used by the recurring runner).
 */

import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import { impersonateAndRun } from "../core/utils";
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
 * The edge's completion check, `RegistryBootstrapMigration.validateApplied()`, as its own call
 * after stage 2; a revert is rethrown with the decoded error.
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
