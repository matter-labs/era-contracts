// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1} from "contracts/core/message-root/IMessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {TotalBatchesExecutedZero, TotalBatchesExecutedLessThanV31UpgradeChainBatchNumber, V31UpgradeChainBatchNumberAlreadySet, CurrentBatchNumberAlreadySet, OnlyOnSettlementLayer} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

contract L1MessageRootV31UpgradeTest is Test {
    address bridgeHub;
    L1MessageRoot messageRoot;

    uint256 constant CHAIN_ID = 271;
    uint256 constant TOTAL_BATCHES_EXECUTED = 100;

    function setUp() public {
        bridgeHub = makeAddr("bridgeHub");

        // Mock getAllZKChainChainIDs to return empty array for constructor
        uint256[] memory allZKChainChainIDs = new uint256[](0);
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(allZKChainChainIDs)
        );

        messageRoot = new L1MessageRoot(bridgeHub, 1);
    }

    function test_L1_CHAIN_ID() public view {
        assertEq(messageRoot.L1_CHAIN_ID(), block.chainid);
    }

    function test_ERA_GATEWAY_CHAIN_ID() public view {
        assertEq(messageRoot.ERA_GATEWAY_CHAIN_ID(), 1);
    }

    function test_RevertWhen_SaveV31UpgradeChainBatchNumber_NotOnSettlementLayer() public {
        address zkChain = makeAddr("zkChain");

        // Mock the chain to be registered
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(zkChain)
        );

        // Mock settlement layer to be a different chain
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, CHAIN_ID),
            abi.encode(999) // Different from block.chainid
        );

        vm.prank(zkChain);
        vm.expectRevert(OnlyOnSettlementLayer.selector);
        messageRoot.saveV31UpgradeChainBatchNumber(CHAIN_ID);
    }

    function test_RevertWhen_SaveV31UpgradeChainBatchNumber_TotalBatchesExecutedZero() public {
        address zkChain = makeAddr("zkChain");

        // Setup mocks
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(zkChain)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, CHAIN_ID),
            abi.encode(block.chainid)
        );
        vm.mockCall(zkChain, abi.encodeWithSelector(IGetters.getTotalBatchesExecuted.selector), abi.encode(0));

        vm.prank(zkChain);
        vm.expectRevert(TotalBatchesExecutedZero.selector);
        messageRoot.saveV31UpgradeChainBatchNumber(CHAIN_ID);
    }

    function test_RevertWhen_SaveV31UpgradeChainBatchNumber_PlaceholderValue() public {
        address zkChain = makeAddr("zkChain");

        // Setup mocks
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(zkChain)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, CHAIN_ID),
            abi.encode(block.chainid)
        );
        // Return the placeholder value which should trigger the revert
        vm.mockCall(
            zkChain,
            abi.encodeWithSelector(IGetters.getTotalBatchesExecuted.selector),
            abi.encode(V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1)
        );

        vm.prank(zkChain);
        vm.expectRevert(TotalBatchesExecutedLessThanV31UpgradeChainBatchNumber.selector);
        messageRoot.saveV31UpgradeChainBatchNumber(CHAIN_ID);
    }
}
