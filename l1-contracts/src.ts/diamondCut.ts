import * as hardhat from "hardhat";
import type { Interface } from "ethers/lib/utils";
import "@nomiclabs/hardhat-ethers";
import type { Wallet, BigNumberish } from "ethers";
import { ethers } from "ethers";
import { IZkSyncHyperchainFactory } from "../typechain/IZkSyncHyperchainFactory";
import { IZkSyncHyperchainBaseFactory } from "../typechain/IZkSyncHyperchainBaseFactory";

// Some of the facets are to be removed with the upcoming upgrade.
const UNCONDITIONALLY_REMOVED_FACETS = ["DiamondCutFacet", "GovernanceFacet"];

export enum Action {
  Add = 0,
  Replace = 1,
  Remove = 2,
}

export interface FacetCut {
  facet: string;
  selectors: string[];
  action: Action;
  isFreezable: boolean;
}

export interface DiamondCut {
  facetCuts: FacetCut[];
  initAddress: string;
  initCalldata: string;
}

export interface InitializeData {
  bridgehub: BigNumberish;
  verifier: BigNumberish;
  admin: BigNumberish;
  genesisBatchHash: string;
  genesisIndexRepeatedStorageChanges: BigNumberish;
  genesisBatchCommitment: string;
  allowList: BigNumberish;
  l2BootloaderBytecodeHash: string;
  l2DefaultAccountBytecodeHash: string;
  priorityTxMaxGasLimit: BigNumberish;
}

export function facetCut(address: string, contract: Interface, action: Action, isFreezable: boolean): FacetCut {
  return {
    facet: address,
    selectors: getAllSelectors(contract),
    action,
    isFreezable,
  };
}

export function diamondCut(facetCuts: FacetCut[], initAddress: string, initCalldata: string): DiamondCut {
  return {
    facetCuts,
    initAddress,
    initCalldata,
  };
}

export function getAllSelectors(contractInterface: Interface) {
  return Object.keys(contractInterface.functions)
    .filter((signature) => {
      return signature !== "getName()";
    })
    .map((signature) => contractInterface.getSighash(signature));
}

export async function getCurrentFacetCutsForAdd(
  adminAddress: string,
  gettersAddress: string,
  mailboxAddress: string,
  executorAddress: string
) {
  const facetsCuts = {};
  // Some facets should always be available regardless of freezing: upgradability system, getters, etc.
  // And for some facets there are should be possibility to freeze them by the admin if we found a bug inside.
  if (adminAddress) {
    // Should be unfreezable. The function to unfreeze contract is located on the admin facet.
    // That means if the admin facet will be freezable, the proxy can NEVER be unfrozen.
    const adminFacet = await hardhat.ethers.getContractAt("AdminFacet", adminAddress);
    facetsCuts["AdminFacet"] = facetCut(adminFacet.address, adminFacet.interface, Action.Add, false);
  }
  if (gettersAddress) {
    // Should be unfreezable. There are getters, that users can expect to be available.
    const getters = await hardhat.ethers.getContractAt("GettersFacet", gettersAddress);
    facetsCuts["GettersFacet"] = facetCut(getters.address, getters.interface, Action.Add, false);
  }
  // These contracts implement the logic without which we can get out of the freeze.
  // These contracts implement the logic without which we can get out of the freeze.
  if (mailboxAddress) {
    const mailbox = await hardhat.ethers.getContractAt("MailboxFacet", mailboxAddress);
    facetsCuts["MailboxFacet"] = facetCut(mailbox.address, mailbox.interface, Action.Add, true);
  }
  if (executorAddress) {
    const executor = await hardhat.ethers.getContractAt("ExecutorFacet", executorAddress);
    facetsCuts["ExecutorFacet"] = facetCut(executor.address, executor.interface, Action.Add, true);
  }

  return facetsCuts;
}

export async function getDeployedFacetCutsForRemove(wallet: Wallet, zkSyncAddress: string, updatedFaceNames: string[]) {
  const mainContract = IZkSyncHyperchainFactory.connect(zkSyncAddress, wallet);
  const diamondCutFacets = await mainContract.facets();
  // We don't care about freezing, because we are removing the facets.
  const result = [];
  for (const { addr, selectors } of diamondCutFacets) {
    const facet = IZkSyncHyperchainBaseFactory.connect(addr, wallet);
    const facetName = await facet.getName();
    if (updatedFaceNames.includes(facetName)) {
      result.push({
        facet: ethers.constants.AddressZero,
        selectors,
        action: Action.Remove,
        isFreezable: false,
      });
    }
  }

  return result;
}

export async function getFacetCutsForUpgrade(
  wallet: Wallet,
  zkSyncAddress: string,
  adminAddress: string,
  gettersAddress: string,
  mailboxAddress: string,
  executorAddress: string,
  namesOfFacetsToBeRemoved?: string[]
) {
  const newFacetCuts = await getCurrentFacetCutsForAdd(adminAddress, gettersAddress, mailboxAddress, executorAddress);
  namesOfFacetsToBeRemoved = namesOfFacetsToBeRemoved || [
    ...UNCONDITIONALLY_REMOVED_FACETS,
    ...Object.keys(newFacetCuts),
  ];
  const oldFacetCuts = await getDeployedFacetCutsForRemove(wallet, zkSyncAddress, namesOfFacetsToBeRemoved);
  return [...oldFacetCuts, ...Object.values(newFacetCuts)];
}
