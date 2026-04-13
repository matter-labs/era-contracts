// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

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
import {Reentrancy} from "contracts/common/L1ContractErrors.sol";

import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER,
    L2_INTEROP_HANDLER_ADDR,
    L2_MESSAGE_VERIFICATION
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

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
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
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
            console.log("Revert reason selector: %s", vm.toString(bytes4(reason)));
            // Check that it's not a reentrancy error          
            // The InteropHandler contract used our custom ReentrancyGuard implementation, not the OZ one
            assertFalse(
                reason.length >= 4 && bytes4(reason) == Reentrancy.selector,
                "Should not revert due to reentrancy"
            );
        }
    }

    /// @notice Test that executeBundle doesn't have nonReentrant modifier blocking nested calls
    /// @dev Creates an outer bundle that calls receiveMessage on InteropHandler,
    ///      which dispatches to this.executeBundle() for an inner bundle.
    ///      With nonReentrant present, the nested executeBundle call triggers reentrancy.
    function test_regression_executeBundleNoReentrancyGuard() public {
        uint256 sourceChainId = block.chainid;

        // Create the inner bundle that will be executed via receiveMessage -> executeBundle
        InteropCall[] memory innerCalls = new InteropCall[](1);
        innerCalls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            from: bundleExecutor,
            to: makeAddr("innerRecipient"),
            value: 0,
            data: hex""
        });

        InteropBundle memory innerBundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            interopBundleSalt: bytes32(uint256(1)),
            calls: innerCalls,
            bundleAttributes: _createBundleAttributes(bundleExecutor)
        });

        bytes memory encodedInnerBundle = abi.encode(innerBundle);
        MessageInclusionProof memory innerProof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Payload for receiveMessage that dispatches to executeBundle(innerBundle)
        bytes memory innerPayload = abi.encodeCall(IInteropHandler.executeBundle, (encodedInnerBundle, innerProof));

        // Outer bundle: its call targets InteropHandler.receiveMessage with the above payload.
        // Call chain: executeBundle(outer) -> _executeCalls -> receiveMessage -> this.executeBundle(inner)
        InteropCall[] memory outerCalls = new InteropCall[](1);
        outerCalls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            from: bundleExecutor,
            to: L2_INTEROP_HANDLER_ADDR,
            value: 0,
            data: innerPayload
        });

        InteropBundle memory outerBundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            interopBundleSalt: bytes32(uint256(2)),
            calls: outerCalls,
            bundleAttributes: _createBundleAttributes(bundleExecutor)
        });

        bytes memory encodedOuterBundle = abi.encode(outerBundle);
        MessageInclusionProof memory outerProof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Mock the message verification to return true
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Mock receiveMessage on recipient to return correct selector
        vm.mockCall(
            makeAddr("innerRecipient"),
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );

        // Switch to destination chain
        vm.chainId(destinationChainId);

        // It should revert due to ExecutingNotAllowed or similar
        // The key assertion is that if we see a revert, it's not the reentrancy revert
        vm.prank(bundleExecutor);
        try L2_INTEROP_HANDLER.executeBundle(encodedOuterBundle, outerProof) {
            // Success - reentrancy did not block the nested executeBundle call
        } catch (bytes memory reason) {
            console.log("Revert reason selector: %s", vm.toString(bytes4(reason)));
            assertFalse(
                reason.length >= 4 && bytes4(reason) == Reentrancy.selector,
                "Should not revert due to reentrancy"
            );
        }
    }

    /// @notice Test that verifyBundle doesn't have nonReentrant blocking it
    /// @dev Creates an outer bundle that calls receiveMessage on InteropHandler,
    ///      which dispatches to this.verifyBundle() for an inner bundle.
    ///      With nonReentrant present, the nested verifyBundle call triggers reentrancy.
    function test_regression_verifyBundleNoReentrancyGuard() public {
        uint256 sourceChainId = block.chainid;

        // Create the inner bundle that will be verified via receiveMessage -> verifyBundle
        InteropCall[] memory innerCalls = new InteropCall[](1);
        innerCalls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            from: bundleExecutor,
            to: makeAddr("innerRecipient"),
            value: 0,
            data: hex""
        });

        InteropBundle memory innerBundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            interopBundleSalt: bytes32(uint256(1)),
            calls: innerCalls,
            bundleAttributes: _createBundleAttributes(bundleExecutor)
        });

        bytes memory encodedInnerBundle = abi.encode(innerBundle);
        MessageInclusionProof memory innerProof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Payload for receiveMessage that dispatches to verifyBundle(innerBundle)
        bytes memory innerPayload = abi.encodeCall(IInteropHandler.verifyBundle, (encodedInnerBundle, innerProof));

        // Outer bundle: its call targets InteropHandler.receiveMessage with the above payload.
        // Call chain: executeBundle(outer) -> _executeCalls -> receiveMessage -> this.verifyBundle(inner)
        InteropCall[] memory outerCalls = new InteropCall[](1);
        outerCalls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            from: bundleExecutor,
            to: L2_INTEROP_HANDLER_ADDR,
            value: 0,
            data: innerPayload
        });

        InteropBundle memory outerBundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: sourceChainId,
            destinationChainId: destinationChainId,
            destinationBaseTokenAssetId: destinationBaseTokenAssetId,
            interopBundleSalt: bytes32(uint256(2)),
            calls: outerCalls,
            bundleAttributes: _createBundleAttributes(bundleExecutor)
        });

        bytes memory encodedOuterBundle = abi.encode(outerBundle);
        MessageInclusionProof memory outerProof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Mock the message verification to return true
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );

        // Switch to destination chain
        vm.chainId(destinationChainId);

        vm.prank(bundleExecutor);
        try L2_INTEROP_HANDLER.executeBundle(encodedOuterBundle, outerProof) {
            // Success - reentrancy did not block the nested verifyBundle call
        } catch (bytes memory reason) {
            console.log("Revert reason selector: %s", vm.toString(bytes4(reason)));
            assertFalse(
                reason.length >= 4 && bytes4(reason) == Reentrancy.selector,
                "Should not revert due to reentrancy"
            );
        }
    }
    /// @notice Helper to create bundle attributes with execution address
    function _createBundleAttributes(address executor) internal view returns (BundleAttributes memory) {
        return
            BundleAttributes({
                executionAddress: InteroperableAddress.formatEvmV1(destinationChainId, executor),
                unbundlerAddress: InteroperableAddress.formatEvmV1(destinationChainId, executor),
                useFixedFee: false
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
