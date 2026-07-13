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
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION
} from "contracts/common/Messaging.sol";
import {AtomicFinalityProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {EmptyBundle, ExecutingNotAllowed} from "contracts/interop/InteropErrors.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";

import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER,
    L2_INTEROP_HANDLER_ADDR
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
        // but the key is it shouldn't fail due to reentrancy. Atomic interop: a default
        // AtomicFinalityProof suffices (the finality gate is mocked in setUp).
        AtomicFinalityProof memory innerFinality;
        bytes memory innerPayload = abi.encodeCall(L2InteropHandler.verifyBundle, (new bytes(0), innerFinality));

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
        AtomicFinalityProof memory proof;

        // Switch to destination chain
        vm.chainId(destinationChainId);

        // Before the fix: `executeBundle` (nonReentrant) -> _executeCalls -> receiveMessage (nonReentrant)
        // would revert with the reentrancy guard error before any inner-bundle logic ran.
        // After the fix: the nested call is reached; the inner `verifyBundle` decodes an EMPTY bundle and
        // reverts deterministically with EmptyBundle (from `_getBundleData`). Asserting that exact error
        // proves both that the reentrancy guard is gone (a Reentrancy revert would fire first) and that the
        // nested dispatch reached the inner handler.
        vm.prank(bundleExecutor);
        vm.expectRevert(EmptyBundle.selector);
        L2_INTEROP_HANDLER.executeBundle(encodedBundle, proof);
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
        AtomicFinalityProof memory innerProof;

        // Payload for receiveMessage that dispatches to executeBundle(innerBundle)
        bytes memory innerPayload = abi.encodeCall(L2InteropHandler.executeBundle, (encodedInnerBundle, innerProof));

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
        AtomicFinalityProof memory outerProof;

        // Mock receiveMessage on recipient to return correct selector
        vm.mockCall(
            makeAddr("innerRecipient"),
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );

        // Switch to destination chain
        vm.chainId(destinationChainId);

        // The nested `executeBundle` is reached via receiveMessage -> _handleExecuteBundle, proving the
        // reentrancy guard is gone. It then reverts deterministically with ExecutingNotAllowed: the inner
        // bundle's execution address is bound to `destinationChainId`, but the interop sender chain id (from
        // the outer call's `from`) is the source chain, so the execution-permission check fails.
        // Selector-only match: ExecutingNotAllowed carries (bundleHash, caller, executionAddress) args.
        vm.prank(bundleExecutor);
        vm.expectPartialRevert(ExecutingNotAllowed.selector);
        L2_INTEROP_HANDLER.executeBundle(encodedOuterBundle, outerProof);
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
        AtomicFinalityProof memory innerProof;

        // Payload for receiveMessage that dispatches to verifyBundle(innerBundle)
        bytes memory innerPayload = abi.encodeCall(L2InteropHandler.verifyBundle, (encodedInnerBundle, innerProof));

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
        AtomicFinalityProof memory outerProof;

        // Switch to destination chain
        vm.chainId(destinationChainId);

        // The nested `verifyBundle` is permissionless, so it runs to completion (the atomicity gate is
        // mocked in setUp) and marks the inner bundle Verified — the whole outer `executeBundle` therefore
        // succeeds. That success (rather than a mere "didn't revert with reentrancy") is the strongest proof
        // the reentrancy guard is gone; assert the inner bundle was actually verified by the nested call.
        bytes32 innerBundleHash = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedInnerBundle);
        vm.prank(bundleExecutor);
        L2_INTEROP_HANDLER.executeBundle(encodedOuterBundle, outerProof);
        assertEq(
            uint256(L2_INTEROP_HANDLER.bundleStatus(innerBundleHash)),
            uint256(BundleStatus.Verified),
            "nested verifyBundle should have marked the inner bundle Verified"
        );
    }
    /// @notice Helper to create bundle attributes with execution address
    function _createBundleAttributes(address executor) internal view returns (BundleAttributes memory) {
        return
            BundleAttributes({
                executionAddress: InteroperableAddress.formatEvmV1(destinationChainId, executor),
                unbundlerAddress: InteroperableAddress.formatEvmV1(destinationChainId, executor),
                useFixedFee: false,
                salt: bytes32(0)
            });
    }
}
