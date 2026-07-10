// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";

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
import {IInteropHandlerBase} from "contracts/interop/interop-handler/IInteropHandlerBase.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {EmptyBundle} from "contracts/interop/InteropErrors.sol";

import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER,
    L2_INTEROP_HANDLER_ADDR,
    L2_MESSAGE_VERIFICATION
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";

/// @title L2InteropHandlerReentrancyRegressionTestAbstract
/// @notice Regression tests for the reentrancy fix in L2InteropHandler
abstract contract L2InteropHandlerReentrancyRegressionTestAbstract is L2InteropTestUtils {
    address internal bundleExecutor;

    function setUp() public virtual override {
        super.setUp();
        bundleExecutor = makeAddr("bundleExecutor");
    }

    /// @notice Test that a bundle can call receiveMessage on L2InteropHandler via _executeCalls
    /// @dev This tests the basic scenario where a bundle contains a call to L2InteropHandler
    ///      Before the fix: This would revert with ReentrancyGuard error
    ///      After the fix: This should not revert due to reentrancy (may fail for other reasons)
    function test_regression_bundleCanCallReceiveMessageOnInteropHandler() public {
        // Create a simple bundle that targets L2InteropHandler's receiveMessage
        // When executed, the bundle will call interopHandler.receiveMessage(...)
        // receiveMessage requires msg.sender == address(this), which is satisfied
        // when called from _executeCalls

        uint256 sourceChainId = block.chainid;

        // Create the inner payload for receiveMessage
        // We'll use verifyBundle selector with empty data - it will fail validation
        // but the key is it shouldn't fail due to reentrancy
        bytes memory innerPayload = abi.encodeCall(
            IInteropHandlerBase.verifyBundle,
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

        // Create the outer bundle that calls receiveMessage on L2InteropHandler
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
            bundleAttributes: _createBundleAttributes(destinationChainId, bundleExecutor)
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

        // Positive oracle: the nested self-call gets PAST the (formerly blocking) reentrancy guard all the way
        // into the inner `verifyBundle`, which then rejects the empty inner bundle with the deterministic
        // `EmptyBundle` error that bubbles up verbatim. Before the fix this reverted with `Reentrancy` instead,
        // before ever reaching the inner validation.
        vm.prank(bundleExecutor);
        vm.expectRevert(EmptyBundle.selector);
        L2_INTEROP_HANDLER.executeBundle(encodedBundle, proof);
    }

    /// @notice Test that executeBundle doesn't have nonReentrant modifier blocking nested calls
    /// @dev Creates an outer bundle that calls receiveMessage on L2InteropHandler,
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
            // The nested `executeBundle` is authorized against the interop-message sender, whose ERC-7930 chain
            // id is the SOURCE chain — so the inner execution address must carry `sourceChainId` for the nested
            // execution to be permitted (which lets this test assert full success rather than a permission revert).
            bundleAttributes: _createBundleAttributes(sourceChainId, bundleExecutor)
        });

        bytes memory encodedInnerBundle = abi.encode(innerBundle);
        MessageInclusionProof memory innerProof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Payload for receiveMessage that dispatches to executeBundle(innerBundle)
        bytes memory innerPayload = abi.encodeCall(IInteropHandlerBase.executeBundle, (encodedInnerBundle, innerProof));

        // Outer bundle: its call targets L2InteropHandler.receiveMessage with the above payload.
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
            bundleAttributes: _createBundleAttributes(destinationChainId, bundleExecutor)
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

        // Positive oracle: with no reentrancy guard blocking the nested self-call, the WHOLE chain
        // executeBundle(outer) -> receiveMessage -> this.executeBundle(inner) succeeds and BOTH bundles end up
        // fully executed. Before the fix this reverted with `Reentrancy` at the nested call.
        vm.prank(bundleExecutor);
        L2_INTEROP_HANDLER.executeBundle(encodedOuterBundle, outerProof);

        assertTrue(
            L2_INTEROP_HANDLER.bundleStatus(InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedOuterBundle)) ==
                BundleStatus.FullyExecuted,
            "outer bundle must be fully executed"
        );
        assertTrue(
            L2_INTEROP_HANDLER.bundleStatus(InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedInnerBundle)) ==
                BundleStatus.FullyExecuted,
            "nested bundle must be fully executed through the self-call"
        );
    }

    /// @notice Test that verifyBundle doesn't have nonReentrant blocking it
    /// @dev Creates an outer bundle that calls receiveMessage on L2InteropHandler,
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
            bundleAttributes: _createBundleAttributes(destinationChainId, bundleExecutor)
        });

        bytes memory encodedInnerBundle = abi.encode(innerBundle);
        MessageInclusionProof memory innerProof = getInclusionProof(L2_INTEROP_CENTER_ADDR, sourceChainId);

        // Payload for receiveMessage that dispatches to verifyBundle(innerBundle)
        bytes memory innerPayload = abi.encodeCall(IInteropHandlerBase.verifyBundle, (encodedInnerBundle, innerProof));

        // Outer bundle: its call targets L2InteropHandler.receiveMessage with the above payload.
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
            bundleAttributes: _createBundleAttributes(destinationChainId, bundleExecutor)
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

        // Positive oracle: with no reentrancy guard blocking the nested self-call, the chain
        // executeBundle(outer) -> receiveMessage -> this.verifyBundle(inner) succeeds: the outer bundle ends up
        // fully executed and the nested bundle verified. Before the fix this reverted with `Reentrancy`.
        vm.prank(bundleExecutor);
        L2_INTEROP_HANDLER.executeBundle(encodedOuterBundle, outerProof);

        assertTrue(
            L2_INTEROP_HANDLER.bundleStatus(InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedOuterBundle)) ==
                BundleStatus.FullyExecuted,
            "outer bundle must be fully executed"
        );
        assertTrue(
            L2_INTEROP_HANDLER.bundleStatus(InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedInnerBundle)) ==
                BundleStatus.Verified,
            "nested bundle must be verified through the self-call"
        );
    }
    /// @notice Helper to create bundle attributes with execution/unbundler address on the given chain.
    /// @param chainId The ERC-7930 chain id of the execution/unbundler address (the destination chain for
    /// directly executed bundles; the SOURCE chain for bundles executed through the interop-message self-call,
    /// whose authorized sender carries the source chain id).
    function _createBundleAttributes(uint256 chainId, address executor) internal pure returns (BundleAttributes memory) {
        return
            BundleAttributes({
                executionAddress: InteroperableAddress.formatEvmV1(chainId, executor),
                unbundlerAddress: InteroperableAddress.formatEvmV1(chainId, executor),
                useFixedFee: false,
                salt: bytes32(0)
            });
    }
}
