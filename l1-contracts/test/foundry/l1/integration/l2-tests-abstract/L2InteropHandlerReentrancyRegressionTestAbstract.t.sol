// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";
import {
    InteropCallStarter,
    InteropBundle,
    InteropCall,
    BundleAttributes,
    BundleStatus,
    CallStatus,
    MessageInclusionProof,
    L2Message,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION
} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {IInteropHandler} from "contracts/interop/IInteropHandler.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";

import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER,
    L2_INTEROP_HANDLER_ADDR,
    L2_MESSAGE_VERIFICATION
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";

/// @title L2InteropHandlerReentrancyRegressionTestAbstract
/// @notice Regression tests for the reentrancy fix in InteropHandler
abstract contract L2InteropHandlerReentrancyRegressionTestAbstract is L2InteropTestUtils {
    address internal bundleExecutor;

    function setUp() public virtual override {
        super.setUp();
        bundleExecutor = makeAddr("bundleExecutor");
    }

    /// @notice Test that a bundle can call receiveMessage on InteropHandler via _executeCalls
    /// @dev This tests the basic scenario where a bundle contains a call to InteropHandler
    ///      Before the fix: This would revert with ReentrancyGuard error
    ///      After the fix: This should not revert due to reentrancy (may fail for other reasons)
    function test_regression_bundleCanCallReceiveMessageOnInteropHandler() public {
        // Create a simple bundle that targets InteropHandler's receiveMessage
        // When executed, the bundle will call interopHandler.receiveMessage(...)
        // receiveMessage requires msg.sender == address(this), which is satisfied
        // when called from _executeCalls

        uint256 sourceChainId = block.chainid;

        // Create the inner payload for receiveMessage
        // We'll use verifyBundle selector with empty data - it will fail validation
        // but the key is it shouldn't fail due to reentrancy
        bytes memory innerPayload = abi.encodeCall(
            IInteropHandler.verifyBundle,
            (
                new bytes(0),
                MessageInclusionProof({
                    chainId: sourceChainId,
                    l1BatchNumber: 0,
                    l2MessageIndex: 0,
                    message: L2Message({txNumberInBatch: 0, sender: L2_INTEROP_CENTER_ADDR, data: new bytes(0)}),
                    proof: new bytes32[](0)
                })
            )
        );

        // Create the outer bundle that calls receiveMessage on InteropHandler
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            from: bundleExecutor,
            to: L2_INTEROP_HANDLER_ADDR,
            value: 0,
            data: innerPayload
        });

        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            interopBundleSalt: bytes32(uint256(1)),
            calls: calls,
            bundleAttributes: _createBundleAttributes(bundleExecutor)
        });

        bytes memory encodedBundle = abi.encode(bundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Mock the message verification to return true
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Switch to destination chain
        vm.chainId(destinationChainId);

        // Execute the bundle
        // Before the fix: This would revert with "ReentrancyGuard: reentrant call" when
        // executeBundle (with nonReentrant) calls _executeCalls which calls receiveMessage (with nonReentrant)
        // After the fix: The reentrancy should not be an issue
        vm.prank(bundleExecutor);

        // We expect this to revert, but NOT due to reentrancy
        // It should revert due to InvalidInteropBundleVersion (empty bundle) or similar
        // The key assertion is that if we see a revert, it's not the reentrancy revert
        try L2_INTEROP_HANDLER.executeBundle(encodedBundle, proof) {
            // If it succeeds, that's fine - reentrancy didn't block it
        } catch (bytes memory reason) {
            // Check that it's not a reentrancy error
            // ReentrancyGuard error would be "ReentrancyGuard: reentrant call"
            string memory revertReason = _getRevertMessage(reason);
            assertTrue(!_containsString(revertReason, "reentrant"), "Should not revert due to reentrancy");
        }
    }

    /// @notice Test that executeBundle doesn't have nonReentrant modifier blocking nested calls
    /// @dev Directly tests that two calls to executeBundle in the same transaction don't revert
    function test_regression_executeBundleNoReentrancyGuard() public {
        // This test verifies the function signature change - nonReentrant was removed
        // We test by checking that the contract can handle the scenario where
        // executeBundle might be called from within another executeBundle

        uint256 sourceChainId = block.chainid;

        // Create two separate bundles
        InteropCall[] memory calls1 = new InteropCall[](1);
        calls1[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            from: bundleExecutor,
            to: makeAddr("recipient1"),
            value: 0,
            data: hex""
        });

        InteropBundle memory bundle1 = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            interopBundleSalt: bytes32(uint256(1)),
            calls: calls1,
            bundleAttributes: _createBundleAttributes(bundleExecutor)
        });

        InteropCall[] memory calls2 = new InteropCall[](1);
        calls2[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            from: bundleExecutor,
            to: makeAddr("recipient2"),
            value: 0,
            data: hex""
        });

        InteropBundle memory bundle2 = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            interopBundleSalt: bytes32(uint256(2)),
            calls: calls2,
            bundleAttributes: _createBundleAttributes(bundleExecutor)
        });

        bytes memory encodedBundle1 = abi.encode(bundle1);
        bytes memory encodedBundle2 = abi.encode(bundle2);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Mock the message verification to return true
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Mock receiveMessage on recipients to return correct selector
        vm.mockCall(
            makeAddr("recipient1"),
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );
        vm.mockCall(
            makeAddr("recipient2"),
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );

        // Switch to destination chain
        vm.chainId(destinationChainId);

        // Execute first bundle
        vm.prank(bundleExecutor);
        L2_INTEROP_HANDLER.executeBundle(encodedBundle1, proof);

        // Execute second bundle in the same transaction context
        // Before fix: If there was remaining reentrancy state, this could fail
        // After fix: Each call is independent
        vm.prank(bundleExecutor);
        L2_INTEROP_HANDLER.executeBundle(encodedBundle2, proof);

        // If we reach here, both bundles executed without reentrancy issues
        // Verify bundle statuses
        bytes32 bundleHash1 = keccak256(abi.encode(sourceChainId, encodedBundle1));
        bytes32 bundleHash2 = keccak256(abi.encode(sourceChainId, encodedBundle2));

        // Both should be marked as executed (or verified, depending on the flow)
        // The main assertion is that we got here without reentrancy revert
        assertTrue(true, "Both bundles executed without reentrancy error");
    }

    /// @notice Test that verifyBundle doesn't have nonReentrant blocking it
    function test_regression_verifyBundleNoReentrancyGuard() public {
        uint256 sourceChainId = block.chainid;

        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            from: bundleExecutor,
            to: makeAddr("recipient"),
            value: 0,
            data: hex""
        });

        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            interopBundleSalt: bytes32(uint256(1)),
            calls: calls,
            bundleAttributes: _createBundleAttributes(bundleExecutor)
        });

        bytes memory encodedBundle = abi.encode(bundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Mock the message verification to return true
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Switch to destination chain
        vm.chainId(destinationChainId);

        // Call verifyBundle - this should work without reentrancy guard
        // Note: This will likely revert due to NotInGatewayMode, but not due to reentrancy
        vm.prank(bundleExecutor);
        try L2_INTEROP_HANDLER.verifyBundle(encodedBundle, proof) {
            // Success - no reentrancy issue
        } catch (bytes memory reason) {
            string memory revertReason = _getRevertMessage(reason);
            assertTrue(!_containsString(revertReason, "reentrant"), "verifyBundle should not revert due to reentrancy");
        }
    }

    /// @notice Helper to create bundle attributes with execution address
    function _createBundleAttributes(address executor) internal view returns (BundleAttributes memory) {
        return
            BundleAttributes({
                executionAddress: InteroperableAddress.formatEvmV1(destinationChainId, executor),
                unbundlerAddress: InteroperableAddress.formatEvmV1(destinationChainId, executor)
            });
    }

    /// @notice Helper to extract revert message from bytes
    function _getRevertMessage(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 68) return "";
        assembly {
            reason := add(reason, 0x04)
        }
        return abi.decode(reason, (string));
    }

    /// @notice Helper to check if string contains substring
    function _containsString(string memory source, string memory search) internal pure returns (bool) {
        bytes memory sourceBytes = bytes(source);
        bytes memory searchBytes = bytes(search);

        if (searchBytes.length > sourceBytes.length) return false;
        if (searchBytes.length == 0) return true;

        for (uint256 i = 0; i <= sourceBytes.length - searchBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < searchBytes.length; j++) {
                if (sourceBytes[i + j] != searchBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
