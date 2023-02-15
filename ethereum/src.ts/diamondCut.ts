import { Interface } from 'ethers/lib/utils';

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
    return Object.keys(contractInterface.functions).map((signature) => contractInterface.getSighash(signature));
}
