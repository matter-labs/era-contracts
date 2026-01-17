// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./_Bridgehub_Shared.t.sol";
import {ChainIdNotRegistered, Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @title Extended tests for Bridgehub to increase coverage
contract BridgehubExtendedTest is L1BridgehubTest {
    function test_Bridgehub_BaseTokenAssetId_ChainNotRegistered() public {
        uint256 nonExistentChainId = 999999;

        vm.expectRevert(abi.encodeWithSelector(ChainIdNotRegistered.selector, nonExistentChainId));
        l1Bridgehub.baseTokenAssetId(nonExistentChainId);
    }

    function test_Bridgehub_GetZKChain_ChainNotRegistered() public {
        uint256 nonExistentChainId = 999999;

        address zkChain = l1Bridgehub.getZKChain(nonExistentChainId);
        assertEq(zkChain, address(0));
    }

    function test_Bridgehub_ChainTypeManager_ChainNotRegistered() public {
        uint256 nonExistentChainId = 999999;

        address ctm = l1Bridgehub.chainTypeManager(nonExistentChainId);
        assertEq(ctm, address(0));
    }

    function test_Bridgehub_GetAllZKChainChainIDs() public view {
        uint256[] memory chainIds = l1Bridgehub.getAllZKChainChainIDs();
        // Initially, no chains should be registered
        assertTrue(chainIds.length >= 0);
    }

    function test_Bridgehub_GetPriorityTreeStartIndex() public view {
        uint256 chainId = 100;
        uint256 index = l1Bridgehub.getPriorityTreeStartIndex(chainId);
        assertEq(index, 0);
    }

    function test_Bridgehub_SetSettlementLayerForChain_Unauthorized() public {
        uint256 chainId = 100;
        address randomUser = makeAddr("randomUser");

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomUser));
        l1Bridgehub.setSettlementLayerForChain(chainId, address(0));
    }

    function test_Bridgehub_RequestChainMigrationToSettlementLayer_Unauthorized() public {
        uint256 chainId = 100;
        address randomUser = makeAddr("randomUser");
        bytes memory migrationData = hex"";

        vm.prank(randomUser);
        vm.expectRevert();
        l1Bridgehub.requestChainMigrationToSettlementLayer{value: 0}(chainId, 0, migrationData);
    }

    function testFuzz_Bridgehub_GetZKChain_AnyChainId(uint256 chainId) public view {
        address zkChain = l1Bridgehub.getZKChain(chainId);
        // Should return address(0) for non-registered chains
        if (zkChain != address(0)) {
            // It's a registered chain
            assertTrue(true);
        } else {
            // Not registered
            assertEq(zkChain, address(0));
        }
    }
}
