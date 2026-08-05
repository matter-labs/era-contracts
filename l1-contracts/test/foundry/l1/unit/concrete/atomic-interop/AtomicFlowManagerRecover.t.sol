// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicRecoverable} from "contracts/atomic-interop/IAtomicRecoverable.sol";
import {IAssetRouterShared} from "contracts/bridge/asset-router/IAssetRouterShared.sol";
import {L2_ASSET_ROUTER_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {RecoverToL1NotSupported} from "contracts/common/L1ContractErrors.sol";
import {
    BundleAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall
} from "contracts/common/Messaging.sol";

/// @dev Exposes the internal {AtomicFlowManager._recoverBundle} so its value-refund dispatch can be unit
/// tested in isolation (the surrounding Committed->Revertable->Reverted state machine is exercised by the
/// atomic-interop anvil spec end-to-end).
contract AtomicFlowManagerRecoverHarness is AtomicFlowManager {
    function exposedRecoverBundle(InteropBundle memory _bundle) external {
        _recoverBundle(_bundle);
    }
}

/// @notice Unit tests for the native-value refund branch in {AtomicFlowManager._recoverBundle}.
/// The external asset-router recovery collaborator is mocked so we assert purely the dispatch logic: the
/// destination base-token asset id is forwarded, a value leg is refunded through the router, and a fully
/// non-recoverable bundle succeeds without touching the router.
contract AtomicFlowManagerRecoverTest is Test {
    AtomicFlowManagerRecoverHarness internal manager;

    bytes32 internal constant SOURCE_BASE_TOKEN_ASSET_ID = keccak256("source-base-token");
    bytes32 internal constant OTHER_BASE_TOKEN_ASSET_ID = keccak256("other-base-token");

    uint256 internal constant DEST_CHAIN_ID = 271;
    address internal constant DEPOSITOR = address(0xD3903170);
    address internal constant CALL_TARGET = address(0xCA11);

    function setUp() public {
        manager = new AtomicFlowManagerRecoverHarness();
    }

    /// @dev Builds a single-call bundle with a non-router sender. `destBaseTokenAssetId` selects the
    /// refund path; `value` marks it as a value-carrying leg.
    function _bundle(bytes32 _destBaseTokenAssetId, uint256 _value) internal view returns (InteropBundle memory b) {
        b = _bundleFrom(DEPOSITOR, _destBaseTokenAssetId, _value, "");
    }

    function _bundleFrom(
        address _from,
        bytes32 _destBaseTokenAssetId,
        uint256 _value,
        bytes memory _data
    ) internal view returns (InteropBundle memory b) {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: CALL_TARGET,
            from: _from,
            value: _value,
            data: _data
        });
        b = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: DEST_CHAIN_ID,
            destinationBaseTokenAssetId: _destBaseTokenAssetId,
            interopBundleSalt: bytes32(0),
            calls: calls,
            bundleAttributes: BundleAttributes({
                executionAddress: "",
                unbundlerAddress: "",
                useFixedFee: false,
                salt: bytes32(0)
            })
        });
    }

    /// @dev Dispatch-only: the asset router is mocked, so this asserts that `_recoverBundle` FORWARDS a
    /// direct value leg's refund to `L2AssetRouter.bridgehubRecoverBaseToken` with the correct
    /// (destChainId, source-base-token assetId, from, value). It does NOT exercise the downstream
    /// disbursement — same-base routing to `BaseTokenHolder.recoverBaseToken` vs different-base NTV re-mint
    /// happens inside {L2NativeTokenVault._disburseFailedTransfer}, which is covered on the real stack by
    /// {L2AtomicInteropSendRefundTestAbstract}'s `test_atomicSend_directValueLeg_sameBase_*` /
    /// `..._differentBase_*` tests (and {AtomicRecoveryForgery} for the router->NTV hop).
    function test_recoverBundle_directValueLeg_forwardsSameBaseAssetIdToRouter() public {
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAssetRouterShared.bridgehubRecoverBaseToken.selector),
            ""
        );

        uint256 value = 5 ether;
        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeCall(
                IAssetRouterShared.bridgehubRecoverBaseToken,
                (DEST_CHAIN_ID, SOURCE_BASE_TOKEN_ASSET_ID, DEPOSITOR, value)
            )
        );
        manager.exposedRecoverBundle(_bundle(SOURCE_BASE_TOKEN_ASSET_ID, value));
    }

    /// @dev Dispatch-only counterpart of {test_recoverBundle_directValueLeg_forwardsSameBaseAssetIdToRouter}
    /// for a different destination base token: asserts the manager forwards the destination base-token
    /// assetId (not this chain's) to `bridgehubRecoverBaseToken`. Downstream disbursement is not exercised
    /// here (see that test's note).
    function test_recoverBundle_directValueLeg_forwardsDifferentBaseAssetIdToRouter() public {
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAssetRouterShared.bridgehubRecoverBaseToken.selector),
            ""
        );

        uint256 value = 7 ether;
        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeCall(
                IAssetRouterShared.bridgehubRecoverBaseToken,
                (DEST_CHAIN_ID, OTHER_BASE_TOKEN_ASSET_ID, DEPOSITOR, value)
            )
        );
        manager.exposedRecoverBundle(_bundle(OTHER_BASE_TOKEN_ASSET_ID, value));
    }

    function test_recoverBundle_revertsWhenDestinationIsL1() public {
        // L2->L1 atomic bundles are rejected at send, so recovery must never process an L1-destined bundle:
        // that keeps it away from the append-only L1 counters in L2AssetTracker (whose settlement-layer
        // updates are only correct at send time). Set L1_CHAIN_ID == the builder's DEST_CHAIN_ID so the bundle
        // is L1-destined, and assert the guard reverts before any refund dispatch.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(DEST_CHAIN_ID);

        vm.expectRevert(RecoverToL1NotSupported.selector);
        manager.exposedRecoverBundle(_bundle(SOURCE_BASE_TOKEN_ASSET_ID, 5 ether));
    }

    function test_recoverBundle_pureValueCallIsRefunded() public {
        // A value leg whose direct sender has no per-sender recovery must still succeed: the value
        // refund is dispatched through the router on its own.
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAssetRouterShared.bridgehubRecoverBaseToken.selector),
            ""
        );

        // Does not revert.
        manager.exposedRecoverBundle(_bundle(SOURCE_BASE_TOKEN_ASSET_ID, 1 ether));
    }

    function test_recoverBundle_routerBackedValueDoesNotRefundSeparately() public {
        // Router-produced calls recover through recoverAtomicCall. Their value is part of that burn and
        // must not be refunded a second time through bridgehubRecoverBaseToken.
        bytes memory callData = abi.encodeWithSignature("finalizeDeposit(uint256,bytes32,bytes)");
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector, DEST_CHAIN_ID, callData),
            abi.encode(true)
        );
        vm.mockCallRevert(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAssetRouterShared.bridgehubRecoverBaseToken.selector),
            "double recovery"
        );

        manager.exposedRecoverBundle(_bundleFrom(L2_ASSET_ROUTER_ADDR, SOURCE_BASE_TOKEN_ASSET_ID, 1 ether, callData));
    }

    function test_recoverBundle_succeedsWhenNothingRecoverable() public {
        // No value and a non-asset-router sender: nothing to reverse. The refund must still go through
        // (flipping the leg to Reverted is meaningful on its own) and must not touch the asset router
        // at all — both router entry points are set to revert, so any dispatch would fail the test.
        vm.mockCallRevert(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAssetRouterShared.bridgehubRecoverBaseToken.selector),
            "unexpected value refund"
        );
        vm.mockCallRevert(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector),
            "unexpected recovery"
        );
        manager.exposedRecoverBundle(_bundle(SOURCE_BASE_TOKEN_ASSET_ID, 0));
    }

    function test_recoverBundle_nonRouterIndirectStarterIsNotDispatched() public {
        // Defense-in-depth: send-time validation (`IndirectCallOnlyToAssetRouter`) makes the asset
        // router the only possible indirect call sender, so a non-router `from` is always treated as a
        // direct call. Even for a bundle shaped like a non-router indirect call, the manager must not
        // probe the sender (a revert would block the whole claim): its recoverAtomicCall and both
        // router entry points are set to revert, so any dispatch would fail the test; the claim still
        // goes through.
        address starter = makeAddr("customIndirectStarter");
        bytes memory callData = abi.encodeWithSignature("finalizeDeposit(uint256,bytes32,bytes)");
        vm.mockCallRevert(
            starter,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector),
            "unexpected non-router recovery"
        );
        vm.mockCallRevert(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector),
            "unexpected recovery"
        );
        vm.mockCallRevert(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAssetRouterShared.bridgehubRecoverBaseToken.selector),
            "unexpected value refund"
        );
        manager.exposedRecoverBundle(_bundleFrom(starter, SOURCE_BASE_TOKEN_ASSET_ID, 0, callData));
    }
}
