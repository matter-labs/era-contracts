// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {StateTransitionDeployedAddresses} from "deploy-scripts/Utils.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {GW_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

abstract contract DeployIntegrationUtils is Script, DeployUtils {
    using stdToml for string;

    function test() internal virtual override {}

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory);

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
                facet: addresses.stateTransition.adminFacet,
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: adminFacetSelectorsArray
            });
            facetCuts[1] = Diamond.FacetCut({
                facet: addresses.stateTransition.gettersFacet,
                action: Diamond.Action.Add,
                isFreezable: false,
                selectors: gettersFacetSelectorsArray
            });
            facetCuts[2] = Diamond.FacetCut({
                facet: addresses.stateTransition.mailboxFacet,
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: mailboxFacetSelectorsArray
            });
            facetCuts[3] = Diamond.FacetCut({
                facet: addresses.stateTransition.executorFacet,
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: executorFacetSelectorsArray
            });
        }
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        return getChainCreationFacetCuts(stateTransition);
    }

    function clearPriorityQueue(address _bridgehub, uint256 _chainId) public {
        IZKChain chain = IZKChain(IBridgehubBase(_bridgehub).getZKChain(_chainId));
        uint256 treeSize = chain.getPriorityQueueSize();
        // The priorityTree sits at slot 51 of ZKChainStorage
        // unprocessedIndex is the second field (51 + 1 = 52) in PriorityTree.Tree
        bytes32 slot = bytes32(uint256(52));
        uint256 value = uint256(vm.load(address(chain), slot));
        // We modify the unprocessedIndex so that the tree size is zero
        vm.store(address(chain), slot, bytes32(value + treeSize));
    }

    function pauseDepositsBeforeInitiatingMigration(address _bridgehub, uint256 _chainId) public {
        IZKChain chain = IZKChain(IBridgehubBase(_bridgehub).getZKChain(_chainId));
        uint256 l1ChainId = IL1Bridgehub(_bridgehub).L1_CHAIN_ID();
        vm.prank(GW_ASSET_TRACKER_ADDR);
        IMailboxImpl(address(chain)).pauseDepositsOnGateway(block.timestamp);
        vm.warp(block.timestamp + 1);
    }
}
