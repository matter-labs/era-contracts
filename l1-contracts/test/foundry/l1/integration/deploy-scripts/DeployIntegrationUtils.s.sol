// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {StateTransitionDeployedAddresses, FacetCut, Action} from "deploy-scripts/Utils.sol";

abstract contract DeployIntegrationUtils is Script, DeployUtils {
    using stdToml for string;

    function test() internal virtual override {}

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory);

    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (FacetCut[] memory facetCuts) {
        string memory root = vm.projectRoot();
        string memory inputPath = string.concat(root, "/script-out/diamond-selectors.toml");
        string memory toml = vm.readFile(inputPath);

        facetCuts = new FacetCut[](4);
        {
            bytes memory adminFacetSelectors = toml.readBytes("$.admin_facet_selectors");
            bytes memory gettersFacetSelectors = toml.readBytes("$.getters_facet_selectors");
            bytes memory mailboxFacetSelectors = toml.readBytes("$.mailbox_facet_selectors");
            bytes memory executorFacetSelectors = toml.readBytes("$.executor_facet_selectors");

            bytes4[] memory adminFacetSelectorsArray = abi.decode(adminFacetSelectors, (bytes4[]));
            bytes4[] memory gettersFacetSelectorsArray = abi.decode(gettersFacetSelectors, (bytes4[]));
            bytes4[] memory mailboxFacetSelectorsArray = abi.decode(mailboxFacetSelectors, (bytes4[]));
            bytes4[] memory executorFacetSelectorsArray = abi.decode(executorFacetSelectors, (bytes4[]));

            facetCuts[0] = FacetCut({
                facet: addresses.stateTransition.adminFacet,
                action: Action.Add,
                isFreezable: false,
                selectors: adminFacetSelectorsArray
            });
            facetCuts[1] = FacetCut({
                facet: addresses.stateTransition.gettersFacet,
                action: Action.Add,
                isFreezable: false,
                selectors: gettersFacetSelectorsArray
            });
            facetCuts[2] = FacetCut({
                facet: addresses.stateTransition.mailboxFacet,
                action: Action.Add,
                isFreezable: true,
                selectors: mailboxFacetSelectorsArray
            });
            facetCuts[3] = FacetCut({
                facet: addresses.stateTransition.executorFacet,
                action: Action.Add,
                isFreezable: true,
                selectors: executorFacetSelectorsArray
            });
        }
    }
}
