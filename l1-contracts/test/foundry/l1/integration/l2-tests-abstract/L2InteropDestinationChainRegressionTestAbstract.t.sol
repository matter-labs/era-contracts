// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {DestinationChainNotRegistered} from "contracts/interop/InteropErrors.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";

import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";

/// @title L2InteropDestinationChainRegressionTestAbstract
/// @notice Regression tests for the unregistered destination chain check (PR #1811)
abstract contract L2InteropDestinationChainRegressionTestAbstract is L2InteropTestUtils {
    // An unregistered chain ID (no baseTokenAssetId set)
    uint256 internal constant UNREGISTERED_CHAIN_ID = 999999;

    function setUp() public virtual override {
        super.setUp();
    }

    /// @notice Test that sending to an unregistered destination chain reverts
    /// @dev This is the main regression test - ensures the fix properly rejects unregistered chains
    function test_regression_sendToUnregisteredChainReverts() public {
        // Mock the bridgehub to return bytes32(0) for the unregistered chain's baseTokenAssetId
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (UNREGISTERED_CHAIN_ID)),
            abi.encode(bytes32(0))
        );

        // Build a simple interop call to the unregistered chain
        bytes[] memory callAttributes = new bytes[](0);

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(makeAddr("someTarget")),
            data: hex"1234",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        // Attempt to send the bundle - should revert with DestinationChainNotRegistered
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotRegistered.selector, UNREGISTERED_CHAIN_ID));
        L2_INTEROP_CENTER.sendBundle(InteroperableAddress.formatEvmV1(UNREGISTERED_CHAIN_ID), calls, bundleAttributes);
    }

    /// @notice Test that sending with value to an unregistered chain also reverts
    /// @dev Ensures the check happens before any value handling
    function test_regression_sendWithValueToUnregisteredChainReverts() public {
        uint256 interopCallValue = 1 ether;

        // Mock the bridgehub to return bytes32(0) for the unregistered chain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (UNREGISTERED_CHAIN_ID)),
            abi.encode(bytes32(0))
        );

        // Build a call with interopCallValue
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(makeAddr("someTarget")),
            data: hex"1234",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        vm.deal(address(this), interopCallValue);

        // Should revert with DestinationChainNotRegistered before processing any value
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotRegistered.selector, UNREGISTERED_CHAIN_ID));
        L2_INTEROP_CENTER.sendBundle{value: interopCallValue}(
            InteroperableAddress.formatEvmV1(UNREGISTERED_CHAIN_ID),
            calls,
            bundleAttributes
        );
    }

    /// @notice Test that sending to a registered chain still works
    /// @dev Ensures the fix doesn't break normal operation
    function test_regression_sendToRegisteredChainWorks() public {
        // destinationChainId from parent class has a registered baseTokenAssetId
        bytes[] memory callAttributes = new bytes[](0);

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(makeAddr("someTarget")),
            data: hex"1234",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        // This should NOT revert (chain is registered)
        bytes32 bundleHash = L2_INTEROP_CENTER.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify a bundle hash was returned
        assertNotEq(bundleHash, bytes32(0), "Bundle hash should be non-zero for registered chain");
    }

    /// @notice Test multiple bundles - one to registered, one to unregistered
    /// @dev Shows that the check is per-bundle, not global
    function test_regression_multipleDestinations() public {
        // First, send to a registered chain - should work
        bytes[] memory callAttributes = new bytes[](0);
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(makeAddr("target1")),
            data: hex"1234",
            callAttributes: callAttributes
        });
        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        // Send to registered chain - should succeed
        bytes32 bundleHash1 = L2_INTEROP_CENTER.sendBundle(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );
        assertNotEq(bundleHash1, bytes32(0), "First bundle to registered chain should succeed");

        // Now try to send to unregistered chain - should fail
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (UNREGISTERED_CHAIN_ID)),
            abi.encode(bytes32(0))
        );

        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotRegistered.selector, UNREGISTERED_CHAIN_ID));
        L2_INTEROP_CENTER.sendBundle(InteroperableAddress.formatEvmV1(UNREGISTERED_CHAIN_ID), calls, bundleAttributes);
    }

    /// @notice Fuzz test with various unregistered chain IDs
    /// @dev Ensures the check works for any chain ID that isn't registered
    function testFuzz_regression_unregisteredChainIdsReverted(uint256 randomChainId) public {
        // Skip if the chainId happens to be our already-registered destinationChainId or current chain
        vm.assume(randomChainId != destinationChainId);
        vm.assume(randomChainId != block.chainid);
        vm.assume(randomChainId != 0);
        // Skip L1_CHAIN_ID - sending to L1 triggers NotL2ToL2 error before DestinationChainNotRegistered
        vm.assume(randomChainId != L1_CHAIN_ID);

        // Mock the bridgehub to return bytes32(0) for this random chain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (randomChainId)),
            abi.encode(bytes32(0))
        );

        bytes[] memory callAttributes = new bytes[](0);
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(makeAddr("target")),
            data: hex"1234",
            callAttributes: callAttributes
        });
        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotRegistered.selector, randomChainId));
        L2_INTEROP_CENTER.sendBundle(InteroperableAddress.formatEvmV1(randomChainId), calls, bundleAttributes);
    }
}
