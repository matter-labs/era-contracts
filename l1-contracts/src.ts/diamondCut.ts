import * as hardhat from "hardhat";
import * as ethers from "ethers";
import "@nomicfoundation/hardhat-ethers";
import { HDNodeWallet, Interface, Wallet } from "ethers";
import { IZkSync__factory } from "../typechain-types";
import { IBase__factory } from "../typechain-types";

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
  return Object.keys(contractInterface.fragments)
    .filter((signature) => {
      return signature !== "getName()";
    })
    .map((signature) => contractInterface.getFunction(signature).selector);
}

export async function getCurrentFacetCutsForAdd(
  adminAddress: string,
  gettersAddress: string,
  mailboxAddress: string,
  executorAddress: string
) {
  const facetsCuts = {};
  // Some facets should always be available regardless of freezing: upgradability system, getters, etc.
  // And for some facets there are should be possibility to freeze them by the governor if we found a bug inside.
  if (adminAddress) {
    // Should be unfreezable. The function to unfreeze contract is located on the admin facet.
    // That means if the admin facet will be freezable, the proxy can NEVER be unfrozen.
    const adminFacet = await hardhat.ethers.getContractAt("AdminFacet", adminAddress);
    facetsCuts["AdminFacet"] = facetCut(await adminFacet.getAddress(), adminFacet.interface, Action.Add, false);
  }
  if (gettersAddress) {
    // Should be unfreezable. There are getters, that users can expect to be available.
    const getters = await hardhat.ethers.getContractAt("GettersFacet", gettersAddress);
    facetsCuts["GettersFacet"] = facetCut(await getters.getAddress(), getters.interface, Action.Add, false);
  }
  // These contracts implement the logic without which we can get out of the freeze.
  if (mailboxAddress) {
    const mailbox = await hardhat.ethers.getContractAt("MailboxFacet", mailboxAddress);
    facetsCuts["MailboxFacet"] = facetCut(await mailbox.getAddress(), mailbox.interface, Action.Add, true);
  }
  if (executorAddress) {
    const executor = await hardhat.ethers.getContractAt("ExecutorFacet", executorAddress);
    facetsCuts["ExecutorFacet"] = facetCut(await executor.getAddress(), executor.interface, Action.Add, true);
  }

  return facetsCuts;
}

export async function getDeployedFacetCutsForRemove(wallet: Wallet | HDNodeWallet, zkSyncAddress: string, updatedFaceNames: string[]) {
  const mainContract = IZkSync__factory.connect(zkSyncAddress, wallet);
  const diamondCutFacets = await mainContract.facets();
  // We don't care about freezing, because we are removing the facets.
  const result = [];
  for (const { addr, selectors } of diamondCutFacets) {
    const facet = IBase__factory.connect(addr, wallet);
    const facetName = await facet.getName();
    if (updatedFaceNames.includes(facetName)) {
      result.push({
        facet: ethers.ZeroHash,
        selectors,
        action: Action.Remove,
        isFreezable: false,
      });
    }
  }
  return result;
}

export async function getFacetCutsForUpgrade(
  wallet: Wallet | HDNodeWallet,
  zkSyncAddress: string,
  adminAddress: string,
  gettersAddress: string,
  mailboxAddress: string,
  executorAddress: string
) {
  const newFacetCuts = await getCurrentFacetCutsForAdd(adminAddress, gettersAddress, mailboxAddress, executorAddress);
  const namesOfFacetsToBeRemoved = [...UNCONDITIONALLY_REMOVED_FACETS, ...Object.keys(newFacetCuts)];
  const oldFacetCuts = await getDeployedFacetCutsForRemove(wallet, zkSyncAddress, namesOfFacetsToBeRemoved);
  return [...oldFacetCuts, ...Object.values(newFacetCuts)];
}
