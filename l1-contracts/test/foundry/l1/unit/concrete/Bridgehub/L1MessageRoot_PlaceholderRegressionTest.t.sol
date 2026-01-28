// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1} from "contracts/core/message-root/IMessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {V31UpgradeChainBatchNumberAlreadySet} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

/// @title L1MessageRootPlaceholderRegressionTest
/// @notice Regression tests for the V31 upgrade batch number placeholder fix
contract L1MessageRootPlaceholderRegressionTest is Test {
    address bridgeHub;

    uint256 constant CHAIN_ID = 271;
    uint256 constant TOTAL_BATCHES_EXECUTED = 100;

    /// @notice Test demonstrating the regression: chains with placeholder value can be updated
    /// @dev Before the fix, this would have failed because the check was `mapping == 0`
    ///      but the mapping had a placeholder value (not 0)
    function test_regression_chainWithPlaceholderCanBeUpdated() public {
        bridgeHub = makeAddr("bridgeHub");

        // Setup: Create a MessageRoot where the chain is initialized with a placeholder
        // This simulates what happens during the V31 upgrade for existing chains
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = CHAIN_ID;

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(chainIds)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, CHAIN_ID),
            abi.encode(block.chainid)
        );

        L1MessageRoot messageRoot = new L1MessageRoot(bridgeHub, 1);

        // Verify the placeholder value was set (not 0!)
        uint256 storedValue = messageRoot.v31UpgradeChainBatchNumber(CHAIN_ID);
        assertEq(
            storedValue,
            V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1,
            "Chain should have placeholder value, not 0"
        );
        assertNotEq(storedValue, 0, "Placeholder value should NOT be 0");

        // Setup mocks for the chain to call saveV31UpgradeChainBatchNumber
        address zkChain = makeAddr("zkChain");
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(zkChain)
        );
        vm.mockCall(
            zkChain,
            abi.encodeWithSelector(IGetters.getTotalBatchesExecuted.selector),
            abi.encode(TOTAL_BATCHES_EXECUTED)
        );

        // This call would have FAILED before the fix (when check was == 0)
        // because the placeholder value is NOT 0.
        // After the fix (check == PLACEHOLDER), it succeeds.
        vm.prank(zkChain);
        messageRoot.saveV31UpgradeChainBatchNumber(CHAIN_ID);

        // Verify the value was updated to the real batch number
        assertEq(
            messageRoot.v31UpgradeChainBatchNumber(CHAIN_ID),
            TOTAL_BATCHES_EXECUTED + 1,
            "Batch number should be set to totalBatchesExecuted + 1"
        );
        assertEq(
            messageRoot.currentChainBatchNumber(CHAIN_ID),
            TOTAL_BATCHES_EXECUTED,
            "currentChainBatchNumber should be set"
        );
    }

    /// @notice Test that chains with value 0 (new chains) CANNOT call saveV31UpgradeChainBatchNumber
    /// @dev New chains that were not in allZKChains at upgrade time have v31UpgradeChainBatchNumber == 0
    ///      These chains should not be able to set a batch number (they're already under v31 rules)
    function test_regression_chainWithZeroValueCannotBeUpdated() public {
        bridgeHub = makeAddr("bridgeHub");

        // Create a MessageRoot with NO chains initialized (empty allZKChains)
        uint256[] memory chainIds = new uint256[](0);
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(chainIds)
        );

        L1MessageRoot messageRoot = new L1MessageRoot(bridgeHub, 1);

        // For a chain not in allZKChains, the mapping defaults to 0
        assertEq(messageRoot.v31UpgradeChainBatchNumber(CHAIN_ID), 0, "New chain should have 0, not placeholder");

        // Setup mocks
        address zkChain = makeAddr("zkChain");
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
        vm.mockCall(
            zkChain,
            abi.encodeWithSelector(IGetters.getTotalBatchesExecuted.selector),
            abi.encode(TOTAL_BATCHES_EXECUTED)
        );

        // This should REVERT because the chain has value 0 (not the placeholder)
        vm.prank(zkChain);
        vm.expectRevert(V31UpgradeChainBatchNumberAlreadySet.selector);
        messageRoot.saveV31UpgradeChainBatchNumber(CHAIN_ID);
    }

    /// @notice Test that once the real value is set, it cannot be changed again
    /// @dev After successfully setting the batch number, further calls should revert
    function test_regression_cannotSetTwice() public {
        bridgeHub = makeAddr("bridgeHub");

        // Setup chain with placeholder
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = CHAIN_ID;

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(chainIds)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, CHAIN_ID),
            abi.encode(block.chainid)
        );

        L1MessageRoot messageRoot = new L1MessageRoot(bridgeHub, 1);

        address zkChain = makeAddr("zkChain");
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(zkChain)
        );
        vm.mockCall(
            zkChain,
            abi.encodeWithSelector(IGetters.getTotalBatchesExecuted.selector),
            abi.encode(TOTAL_BATCHES_EXECUTED)
        );

        // First call succeeds
        vm.prank(zkChain);
        messageRoot.saveV31UpgradeChainBatchNumber(CHAIN_ID);

        // Verify value is now the real batch number (not placeholder, not 0)
        uint256 storedValue = messageRoot.v31UpgradeChainBatchNumber(CHAIN_ID);
        assertNotEq(storedValue, V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1, "Should not be placeholder");
        assertNotEq(storedValue, 0, "Should not be 0");

        // Second call should revert
        vm.prank(zkChain);
        vm.expectRevert(); // Will revert due to currentChainBatchNumber already set
        messageRoot.saveV31UpgradeChainBatchNumber(CHAIN_ID);
    }

    /// @notice Test that the placeholder value is a large hash-based value, not 0
    /// @dev Verifies the placeholder is derived from a hash to ensure it's unlikely to collide
    function test_regression_placeholderValueIsLargeHash() public pure {
        // The placeholder should be a hash-derived value
        uint256 expectedPlaceholder = uint256(
            keccak256(abi.encodePacked("V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1"))
        );

        assertEq(
            V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1,
            expectedPlaceholder,
            "Placeholder should be keccak256 of the constant name"
        );

        // Verify it's not 0 and not a small value (collision risk)
        assertNotEq(V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1, 0, "Placeholder must not be 0");
        assertGt(
            V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1,
            type(uint128).max,
            "Placeholder should be a large value"
        );
    }

    /// @notice Fuzz test: various batch numbers should work for chains with placeholder
    /// @dev Ensures the fix works for any valid totalBatchesExecuted value
    function testFuzz_regression_anyValidBatchNumberWorks(uint256 totalBatchesExecuted) public {
        // Skip invalid values
        vm.assume(totalBatchesExecuted > 0);
        vm.assume(totalBatchesExecuted < type(uint256).max); // Prevent overflow in +1
        vm.assume(totalBatchesExecuted != V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1);

        bridgeHub = makeAddr("bridgeHub");

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = CHAIN_ID;

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(chainIds)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, CHAIN_ID),
            abi.encode(block.chainid)
        );

        L1MessageRoot messageRoot = new L1MessageRoot(bridgeHub, 1);

        address zkChain = makeAddr("zkChain");
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(zkChain)
        );
        vm.mockCall(
            zkChain,
            abi.encodeWithSelector(IGetters.getTotalBatchesExecuted.selector),
            abi.encode(totalBatchesExecuted)
        );

        // Should succeed for any valid batch number
        vm.prank(zkChain);
        messageRoot.saveV31UpgradeChainBatchNumber(CHAIN_ID);

        assertEq(
            messageRoot.v31UpgradeChainBatchNumber(CHAIN_ID),
            totalBatchesExecuted + 1,
            "Batch number should be set correctly"
        );
    }
}
