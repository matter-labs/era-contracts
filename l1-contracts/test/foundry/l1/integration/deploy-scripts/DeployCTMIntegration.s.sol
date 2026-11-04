// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DeployCTMScript} from "deploy-scripts/ctm/DeployCTM.s.sol";
import {StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract DeployCTMIntegrationScript is Script, DeployCTMScript {
    using stdToml for string;

    function test() internal virtual override {}

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        string memory root = vm.projectRoot();
        string memory inputPath = string.concat(root, "/script-out/diamond-selectors.toml");
        string memory toml = vm.readFile(inputPath);

        facetCuts = new Diamond.FacetCut[](6);
        facetCuts[0] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: abi.decode(toml.readBytes("$.admin_facet_selectors"), (bytes4[]))
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: abi.decode(toml.readBytes("$.getters_facet_selectors"), (bytes4[]))
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: abi.decode(toml.readBytes("$.mailbox_facet_selectors"), (bytes4[]))
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: abi.decode(toml.readBytes("$.executor_facet_selectors"), (bytes4[]))
        });
        facetCuts[4] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.migratorFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: abi.decode(toml.readBytes("$.migrator_facet_selectors"), (bytes4[]))
        });
        facetCuts[5] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.committerFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: abi.decode(toml.readBytes("$.committer_facet_selectors"), (bytes4[]))
        });
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        return getChainCreationFacetCuts(stateTransition);
    }
}
