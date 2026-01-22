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

        facetCuts = new Diamond.FacetCut[](4);
        {
            bytes memory adminFacetSelectors = toml.readBytes("$.admin_facet_selectors");
            bytes memory gettersFacetSelectors = toml.readBytes("$.getters_facet_selectors");
            bytes memory mailboxFacetSelectors = toml.readBytes("$.mailbox_facet_selectors");
            bytes memory executorFacetSelectors = toml.readBytes("$.executor_facet_selectors");

            bytes4[] memory adminFacetSelectorsArray = abi.decode(adminFacetSelectors, (bytes4[]));
            bytes4[] memory gettersFacetSelectorsArray = abi.decode(gettersFacetSelectors, (bytes4[]));
            bytes4[] memory mailboxFacetSelectorsArray = abi.decode(mailboxFacetSelectors, (bytes4[]));
            bytes4[] memory executorFacetSelectorsArray = abi.decode(executorFacetSelectors, (bytes4[]));

            facetCuts[0] = Diamond.FacetCut({
                facet: ctmAddresses.stateTransition.facets.adminFacet,
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: adminFacetSelectorsArray
            });
            facetCuts[1] = Diamond.FacetCut({
                facet: ctmAddresses.stateTransition.facets.gettersFacet,
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: gettersFacetSelectorsArray
            });
            facetCuts[2] = Diamond.FacetCut({
                facet: ctmAddresses.stateTransition.facets.mailboxFacet,
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: mailboxFacetSelectorsArray
            });
            facetCuts[3] = Diamond.FacetCut({
                facet: ctmAddresses.stateTransition.facets.executorFacet,
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: executorFacetSelectorsArray
            });
        }
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
        return getChainCreationFacetCuts(stateTransition);
    }
}
