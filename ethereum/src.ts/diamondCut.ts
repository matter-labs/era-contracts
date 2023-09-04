import { Interface } from 'ethers/lib/utils';
import * as hardhat from 'hardhat';
import '@nomiclabs/hardhat-ethers';
import { ethers, Wallet } from 'ethers';
import { IZkSyncFactory } from '../typechain/IZkSyncFactory';
import { IBaseFactory } from '../typechain/IBaseFactory';

export enum Action {
    Add = 0,
    Replace = 1,
    Remove = 2
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
        isFreezable
    };
}

export function diamondCut(facetCuts: FacetCut[], initAddress: string, initCalldata: string): DiamondCut {
    return {
        facetCuts,
        initAddress,
        initCalldata
    };
}

export function getAllSelectors(contractInterface: Interface) {
    return Object.keys(contractInterface.functions)
        .filter((signature) => {
            return signature !== 'getName()';
        })
        .map((signature) => contractInterface.getSighash(signature));
}

export async function getCurrentFacetCutsForAdd(
    diamondCutFacetAddress: string,
    gettersAddress: string,
    mailboxAddress: string,
    executorAddress: string,
    governanceAddress: string
) {
    const facetsCuts = {};
    // Some facets should always be available regardless of freezing: upgradability system, getters, etc.
    // And for some facets there are should be possibility to freeze them by the governor if we found a bug inside.
    if (diamondCutFacetAddress) {
        // Should be unfreezable. The function to unfreeze contract is located on the diamond cut facet.
        // That means if the diamond cut will be freezable, the proxy can NEVER be unfrozen.
        const diamondCutFacet = await hardhat.ethers.getContractAt('DiamondCutFacet', diamondCutFacetAddress);
        facetsCuts['DiamondCutFacet'] = facetCut(diamondCutFacet.address, diamondCutFacet.interface, Action.Add, false);
    }
    if (gettersAddress) {
        // Should be unfreezable. There are getters, that users can expect to be available.
        const getters = await hardhat.ethers.getContractAt('GettersFacet', gettersAddress);
        facetsCuts['GettersFacet'] = facetCut(getters.address, getters.interface, Action.Add, false);
    }
    // These contracts implement the logic without which we can get out of the freeze.
    if (mailboxAddress) {
        const mailbox = await hardhat.ethers.getContractAt('MailboxFacet', mailboxAddress);
        facetsCuts['MailboxFacet'] = facetCut(mailbox.address, mailbox.interface, Action.Add, true);
    }
    if (executorAddress) {
        const executor = await hardhat.ethers.getContractAt('ExecutorFacet', executorAddress);
        facetsCuts['ExecutorFacet'] = facetCut(executor.address, executor.interface, Action.Add, true);
    }
    if (governanceAddress) {
        const governance = await hardhat.ethers.getContractAt('GovernanceFacet', governanceAddress);
        facetsCuts['GovernanceFacet'] = facetCut(governance.address, governance.interface, Action.Add, true);
    }
    return facetsCuts;
}

export async function getDeployedFacetCutsForRemove(wallet: Wallet, zkSyncAddress: string, updatedFaceNames: string[]) {
    const mainContract = IZkSyncFactory.connect(zkSyncAddress, wallet);
    const diamondCutFacets = await mainContract.facets();
    // We don't care about freezing, because we are removing the facets.
    const result = [];
    for (const { addr, selectors } of diamondCutFacets) {
        const facet = IBaseFactory.connect(addr, wallet);
        const facetName = await facet.getName();
        if (updatedFaceNames.includes(facetName)) {
            result.push({
                facet: ethers.constants.AddressZero,
                selectors,
                action: Action.Remove,
                isFreezable: false
            });
        }
    }
    return result;
}

export async function getFacetCutsForUpgrade(
    wallet: Wallet,
    zkSyncAddress: string,
    diamondCutFacetAddress: string,
    gettersAddress: string,
    mailboxAddress: string,
    executorAddress: string,
    governanceAddress: string
) {
    const newFacetCuts = await getCurrentFacetCutsForAdd(
        diamondCutFacetAddress,
        gettersAddress,
        mailboxAddress,
        executorAddress,
        governanceAddress
    );
    const oldFacetCuts = await getDeployedFacetCutsForRemove(wallet, zkSyncAddress, Object.keys(newFacetCuts));
    return [...oldFacetCuts, ...Object.values(newFacetCuts)];
}
