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
import {L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

abstract contract DeployIntegrationUtils is Script, DeployCTMUtils {
    function test() internal virtual override {}

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory) {
        return super.getInitializeCalldata(contractName);
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
        vm.prank(L2_CHAIN_ASSET_HANDLER_ADDR);
        IMigrator(address(chain)).pauseDepositsOnGateway(block.timestamp);
        vm.warp(block.timestamp + 1);
    }
}
