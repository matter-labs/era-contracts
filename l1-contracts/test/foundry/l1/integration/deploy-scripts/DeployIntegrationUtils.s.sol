// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";

import {DeployCTMUtils} from "deploy-scripts/ctm/DeployCTMUtils.s.sol";
import {StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {GW_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

abstract contract DeployIntegrationUtils is Script, DeployCTMUtils {
    function test() internal virtual override {}

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        return super.getInitializeCalldata(contractName, isZKBytecode);
    }

    function getChainCreationFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        facetCuts = new Diamond.FacetCut[](6);
        facetCuts[0] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getSelectorsFromArtifact("/out/Admin.sol/AdminFacet.json")
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getSelectorsFromArtifact("/out/Getters.sol/GettersFacet.json")
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getSelectorsFromArtifact("/out/Mailbox.sol/MailboxFacet.json")
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getSelectorsFromArtifact("/out/Executor.sol/ExecutorFacet.json")
        });
        facetCuts[4] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.migratorFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getSelectorsFromArtifact("/out/Migrator.sol/MigratorFacet.json")
        });
        facetCuts[5] = Diamond.FacetCut({
            facet: ctmAddresses.stateTransition.facets.committerFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getSelectorsFromArtifact("/out/Committer.sol/CommitterFacet.json")
        });
    }

    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual returns (Diamond.FacetCut[] memory facetCuts) {
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
        IMigrator(address(chain)).pauseDepositsOnGateway(block.timestamp);
        vm.warp(block.timestamp + 1);
    }
}
