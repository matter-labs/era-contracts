// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {DeployL1ScriptAbstract} from "./DeployL1Abstract.s.sol";

import {StateTransitionDeployedAddresses, Utils, FacetCut, Action} from "./Utils.sol";

contract DeployL1Script is Script, DeployL1ScriptAbstract  {    
    /// @notice Get new facet cuts
    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (FacetCut[] memory facetCuts) {
        // Note: we use the provided stateTransition for the facet address, but not to get the selectors, as we use this feature for Gateway, which we cannot query.
        // If we start to use different selectors for Gateway, we should change this.
        facetCuts = new FacetCut[](4);
        facetCuts[0] = FacetCut({
            facet: stateTransition.adminFacet,
            action: Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = FacetCut({
            facet: stateTransition.gettersFacet,
            action: Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[2] = FacetCut({
            facet: stateTransition.mailboxFacet,
            action: Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[3] = FacetCut({
            facet: stateTransition.executorFacet,
            action: Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.executorFacet.code)
        });
    }

    function test() internal virtual override(DeployL1ScriptAbstract) {}
}