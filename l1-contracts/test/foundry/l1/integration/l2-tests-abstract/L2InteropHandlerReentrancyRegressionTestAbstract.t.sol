// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";
import {
    InteropBundle,
    InteropCall,
    BundleAttributes,
    BundleStatus,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION
} from "contracts/common/Messaging.sol";
import {AtomicFinalityProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {EmptyBundle} from "contracts/interop/InteropErrors.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";

import {L2_INTEROP_HANDLER, L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";

/// @title L2InteropHandlerReentrancyRegressionTestAbstract
/// @notice Regression tests for the reentrancy fix in L2InteropHandler: a bundle call may legitimately
///         re-enter the handler (via the `receiveMessage` self-call from `_executeCalls`) to execute/verify a
///         nested bundle. Before the fix the nonReentrant guard blocked this; these tests assert the nested
///         flow now runs to completion. The atomic finality gate is mocked in setUp, so a default
///         `AtomicFinalityProof` suffices and the assertions exercise the reentrancy path, not proof checks.
abstract contract L2InteropHandlerReentrancyRegressionTestAbstract is L2InteropTestUtils {
    address internal bundleExecutor;

    function setUp() public virtual override {
        super.setUp();
        bundleExecutor = makeAddr("bundleExecutor");
    }

    /// @notice A bundle call may re-enter the handler via `receiveMessage` (self-call from `_executeCalls`).
    /// @dev Before the fix, `executeBundle` (nonReentrant) -> `_executeCalls` -> `receiveMessage` (nonReentrant)
    ///      reverted with the guard error before any inner logic ran. After the fix the nested dispatch is
    ///      reached: here the inner `verifyBundle` decodes an EMPTY bundle and reverts deterministically with
    ///      `EmptyBundle`. Asserting that exact error proves both that the guard is gone (a `Reentrancy` revert
    ///      would fire first) and that the nested dispatch actually reached the inner handler.
    function test_regression_bundleCanCallReceiveMessageOnInteropHandler() public {
        uint256 sourceChainId = block.chainid;

        // Inner payload: verifyBundle over an EMPTY bundle. The finality gate is mocked, so `_getBundleData`'s
        // empty-bundle check — not the gate — is what reverts.
        AtomicFinalityProof memory innerFinality;
        bytes memory innerPayload = abi.encodeCall(L2InteropHandler.verifyBundle, (new bytes(0), innerFinality));

        // Outer bundle whose single call targets L2InteropHandler.receiveMessage with that payload.
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
            // Executed directly by `bundleExecutor` on the destination chain -> execution address on destChain.
            bundleAttributes: _createBundleAttributes(destinationChainId, bundleExecutor)
        });

        bytes memory encodedBundle = abi.encode(bundle);
        AtomicFinalityProof memory proof;

        vm.chainId(destinationChainId);

        vm.prank(bundleExecutor);
        vm.expectRevert(EmptyBundle.selector);
        L2_INTEROP_HANDLER.executeAtomicBundle(encodedBundle, proof);
    }

    /// @notice `executeBundle` must not carry a nonReentrant guard: a bundle may re-enter it (via
    ///         `receiveMessage`) to execute a nested bundle.
    /// @dev Positive oracle: with the guard gone, the whole chain
    ///      executeAtomicBundle(outer) -> receiveMessage -> this.executeAtomicBundle(inner) succeeds and BOTH bundles end up
    ///      `FullyExecuted`. Before the fix the nested call reverted with `Reentrancy`.
    function test_regression_executeBundleNoReentrancyGuard() public {
        uint256 sourceChainId = block.chainid;

        // Inner bundle executed via receiveMessage -> executeBundle. Its single call is a no-op to a mocked
        // recipient.
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
            // execution to be permitted (which is what lets this test assert full success rather than a
            // permission revert).
            bundleAttributes: _createBundleAttributes(sourceChainId, bundleExecutor)
        });

        bytes memory encodedInnerBundle = abi.encode(innerBundle);
        AtomicFinalityProof memory innerProof;

        // Payload for receiveMessage that dispatches to executeBundle(innerBundle)
        bytes memory innerPayload = abi.encodeCall(L2InteropHandler.executeAtomicBundle, (encodedInnerBundle, innerProof));

        // Outer bundle: its call targets L2InteropHandler.receiveMessage with the above payload.
        // Call chain: executeAtomicBundle(outer) -> _executeCalls -> receiveMessage -> this.executeAtomicBundle(inner)
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
        AtomicFinalityProof memory outerProof;

        // The inner bundle's no-op call forwards to the mocked recipient, which returns the ERC-7786 selector.
        vm.mockCall(
            makeAddr("innerRecipient"),
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );

        vm.chainId(destinationChainId);

        vm.prank(bundleExecutor);
        L2_INTEROP_HANDLER.executeAtomicBundle(encodedOuterBundle, outerProof);

        assertTrue(
            L2_INTEROP_HANDLER.bundleStatus(
                InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedOuterBundle)
            ) == BundleStatus.FullyExecuted,
            "outer bundle must be fully executed"
        );
        assertTrue(
            L2_INTEROP_HANDLER.bundleStatus(
                InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedInnerBundle)
            ) == BundleStatus.FullyExecuted,
            "nested bundle must be fully executed through the self-call"
        );
    }

    /// @notice `verifyBundle` must not carry a nonReentrant guard: a bundle may re-enter to verify a nested one.
    /// @dev Positive oracle: executeAtomicBundle(outer) -> receiveMessage -> this.verifyBundle(inner) succeeds, so the
    ///      outer bundle ends up `FullyExecuted` and the nested bundle `Verified`. Before the fix the nested
    ///      call reverted with `Reentrancy`.
    function test_regression_verifyBundleNoReentrancyGuard() public {
        uint256 sourceChainId = block.chainid;

        // Inner bundle verified (not executed) via receiveMessage -> verifyBundle. `verifyBundle` is
        // permissionless, so the inner execution address is not gated here.
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
        AtomicFinalityProof memory innerProof;

        // Payload for receiveMessage that dispatches to verifyBundle(innerBundle)
        bytes memory innerPayload = abi.encodeCall(L2InteropHandler.verifyBundle, (encodedInnerBundle, innerProof));

        // Outer bundle: its call targets L2InteropHandler.receiveMessage with the above payload.
        // Call chain: executeAtomicBundle(outer) -> _executeCalls -> receiveMessage -> this.verifyBundle(inner)
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
        AtomicFinalityProof memory outerProof;

        vm.chainId(destinationChainId);

        vm.prank(bundleExecutor);
        L2_INTEROP_HANDLER.executeAtomicBundle(encodedOuterBundle, outerProof);

        assertTrue(
            L2_INTEROP_HANDLER.bundleStatus(
                InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedOuterBundle)
            ) == BundleStatus.FullyExecuted,
            "outer bundle must be fully executed"
        );
        assertTrue(
            L2_INTEROP_HANDLER.bundleStatus(
                InteropDataEncoding.encodeInteropBundleHash(sourceChainId, encodedInnerBundle)
            ) == BundleStatus.Verified,
            "nested bundle must be verified through the self-call"
        );
    }

    /// @notice Helper: bundle attributes with the execution/unbundler address bound to `chainId`.
    /// @dev The execution-permission gate authorizes against the interop-message sender's ERC-7930 chain id —
    /// the SOURCE chain for a nested (receiveMessage) execution, but `destinationChainId` for a direct top-level
    /// execution — so callers pass the chain id matching how the bundle is executed.
    function _createBundleAttributes(
        uint256 chainId,
        address executor
    ) internal pure returns (BundleAttributes memory) {
        return
            BundleAttributes({
                executionAddress: InteroperableAddress.formatEvmV1(chainId, executor),
                unbundlerAddress: InteroperableAddress.formatEvmV1(chainId, executor),
                useFixedFee: false,
                salt: bytes32(0)
            });
    }
}
