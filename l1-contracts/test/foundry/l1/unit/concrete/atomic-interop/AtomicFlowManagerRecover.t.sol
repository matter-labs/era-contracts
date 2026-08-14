// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {ManagerLegNotRevertable} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {LegState} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IAtomicRecoverable} from "contracts/atomic-interop/IAtomicRecoverable.sol";
import {IAssetRouterShared} from "contracts/bridge/asset-router/IAssetRouterShared.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
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
/// tested in isolation, and lets a leg be forced `Revertable` so the full `claimRefund` state machine
/// (Committed->Revertable->Reverted, with rollback on a failing recovery) can be driven directly.
contract AtomicFlowManagerRecoverHarness is AtomicFlowManager {
    function exposedRecoverBundle(InteropBundle memory _bundle) external {
        _recoverBundle(_bundle);
    }

    function forceRevertable(bytes32 _flowId, bytes32 _bundleHash) external {
        _state[_flowId][_bundleHash] = LegState.Revertable;
    }
}

/// @dev Stateful stand-in for the asset router at its canonical address: unlike `vm.mockCall`, its
/// counters are real storage, so they roll back with a reverting `claimRefund` — which is exactly what
/// the "later recovery reverts" test needs to prove. `recoverAtomicCall` can be scripted per call-data
/// to return true, return false, or revert; `bridgehubRecoverBaseToken` just tallies base-token
/// refunds. Recognised by the manager as the recoverer because it lives at `L2_ASSET_ROUTER_ADDR`.
contract MockRecoveryRouter {
    uint256 public recoverAttempts;
    uint256 public recoverSuccesses;
    uint256 public baseTokenRecoveries;

    mapping(bytes32 dataHash => bool) public returnsFalse;
    mapping(bytes32 dataHash => bool) public reverts;

    function scriptReturnsFalse(bytes calldata _data) external {
        returnsFalse[keccak256(_data)] = true;
    }

    function scriptReverts(bytes calldata _data) external {
        reverts[keccak256(_data)] = true;
    }

    function recoverAtomicCall(uint256 _destChainId, bytes calldata _data) external returns (bool) {
        _destChainId; // unused; recovery routing is not exercised by this stateful stand-in
        ++recoverAttempts;
        if (reverts[keccak256(_data)]) {
            revert("recovery boom");
        }
        if (returnsFalse[keccak256(_data)]) {
            return false;
        }
        ++recoverSuccesses;
        return true;
    }

    function bridgehubRecoverBaseToken(uint256 _destChainId, bytes32 _assetId, address _from, uint256 _value) external {
        (_destChainId, _assetId, _from, _value); // unused; only the tally matters here
        ++baseTokenRecoveries;
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
    bytes32 internal constant FLOW_ID = keccak256("recover-flow");

    uint256 internal constant DEST_CHAIN_ID = 271;
    address internal constant DEPOSITOR = address(0xD3903170);
    address internal constant CALL_TARGET = address(0xCA11);

    function setUp() public {
        manager = new AtomicFlowManagerRecoverHarness();
    }

    /// @dev Builds a single direct-call bundle. `destBaseTokenAssetId` selects the refund path; `value`
    /// marks it as a value-carrying leg.
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
        // that keeps it away from the append-only L1 counters in BaseTokenHolder (whose settlement-layer
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
        // No value and a direct, non-asset-router sender: nothing to reverse. The refund must still go
        // through (flipping the leg to Reverted is meaningful on its own) and must not touch the asset
        // router at all — both router entry points are set to revert, so any dispatch would fail the test.
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

    // ------------------------------------------------------------------------------------------------
    // Multi-call bundles: _recoverBundle iterates EVERY call, so a regression that stopped after the
    // first recovery (or mishandled a false/reverting later call) would strand funds. These use a
    // stateful mock router at the canonical address so recovery side effects — and their rollback — are
    // observable.
    // ------------------------------------------------------------------------------------------------

    /// @dev Deploys the stateful mock router at the canonical asset-router address and returns it.
    function _deployMockRouter() internal returns (MockRecoveryRouter router) {
        deployCodeTo("AtomicFlowManagerRecover.t.sol:MockRecoveryRouter", L2_ASSET_ROUTER_ADDR);
        router = MockRecoveryRouter(L2_ASSET_ROUTER_ADDR);
    }

    /// @dev A multi-call bundle assembled from raw calls (bypasses the single-call `_bundleFrom`).
    function _multiCallBundle(InteropCall[] memory _calls) internal view returns (InteropBundle memory b) {
        b = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: DEST_CHAIN_ID,
            destinationBaseTokenAssetId: SOURCE_BASE_TOKEN_ASSET_ID,
            interopBundleSalt: bytes32(0),
            calls: _calls,
            bundleAttributes: BundleAttributes({
                executionAddress: "",
                unbundlerAddress: "",
                useFixedFee: false,
                salt: bytes32(0)
            })
        });
    }

    function _call(address _from, uint256 _value, bytes memory _data) internal pure returns (InteropCall memory) {
        return
            InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: CALL_TARGET,
                from: _from,
                value: _value,
                data: _data
            });
    }

    /// @notice A bundle mixing [router-backed recovery, non-fund direct call, direct value leg] recovers
    /// EVERY fund-bearing call exactly once and skips the non-fund one — proving the loop processes all
    /// calls, not just the first recoverable one.
    function test_recoverBundle_multiCall_recoversEveryFundBearingCallOnce() public {
        MockRecoveryRouter router = _deployMockRouter();

        InteropCall[] memory calls = new InteropCall[](3);
        calls[0] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"a1a1"); // router-backed -> recoverAtomicCall
        calls[1] = _call(DEPOSITOR, 0, hex""); // direct, no value -> nothing to reverse (skipped)
        calls[2] = _call(DEPOSITOR, 4 ether, hex""); // direct value leg -> base-token recovery

        manager.exposedRecoverBundle(_multiCallBundle(calls));

        assertEq(router.recoverAttempts(), 1, "exactly one router-backed call is asked to recover");
        assertEq(router.recoverSuccesses(), 1, "the router-backed call recovers once");
        assertEq(router.baseTokenRecoveries(), 1, "the direct value leg is refunded once");
    }

    /// @notice A router-backed call that returns `false` (nothing to recover) does not abort the loop: a
    /// LATER recoverable call is still attempted and recovers. Guards against a regression that treated
    /// a `false` as terminal.
    function test_recoverBundle_multiCall_falseThenLaterSuccess() public {
        MockRecoveryRouter router = _deployMockRouter();
        router.scriptReturnsFalse(hex"deed");

        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"deed"); // recoverAtomicCall -> false
        calls[1] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"adad"); // recoverAtomicCall -> true

        manager.exposedRecoverBundle(_multiCallBundle(calls));

        assertEq(router.recoverAttempts(), 2, "both router-backed calls are attempted");
        assertEq(router.recoverSuccesses(), 1, "only the second call actually recovers");
    }

    /// @notice If EVERY router-backed recovery returns `false`, nothing is recovered — and the refund
    /// must STILL go through: a bundle with no recoverable funds has nothing to return, but flipping the
    /// leg to `Reverted` is meaningful on its own and must not be blocked (see
    /// {AtomicFlowManager._recoverBundle}). All calls are attempted, no payout occurs, `FlowRefunded` is
    /// emitted, and the leg lands terminal `Reverted` (a further claim is rejected).
    function test_claimRefund_multiCall_allRouterFalseSucceedsWithoutPayout() public {
        MockRecoveryRouter router = _deployMockRouter();
        router.scriptReturnsFalse(hex"1111");
        router.scriptReturnsFalse(hex"2222");

        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"1111"); // recoverAtomicCall -> false
        calls[1] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"2222"); // recoverAtomicCall -> false

        InteropBundle memory bundle = _multiCallBundle(calls);
        bytes memory bundleBytes = abi.encode(bundle);
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(bundleBytes);
        manager.forceRevertable(FLOW_ID, bundleHash);

        vm.expectEmit(true, true, false, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(FLOW_ID, bundleHash);
        manager.claimRefund(FLOW_ID, bundleBytes);

        assertEq(router.recoverAttempts(), 2, "every router-backed call is still attempted");
        assertEq(router.recoverSuccesses(), 0, "nothing actually recovers");
        assertEq(router.baseTokenRecoveries(), 0, "no base-token payout occurred");
        assertEq(
            uint256(manager.legState(FLOW_ID, bundleHash)),
            uint256(LegState.Reverted),
            "the leg is terminally Reverted even though nothing was recoverable"
        );

        // Terminal: the no-op refund cannot be claimed again.
        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegNotRevertable.selector, FLOW_ID, bundleHash, LegState.Reverted)
        );
        manager.claimRefund(FLOW_ID, bundleBytes);
    }

    /// @notice A later call reverting during recovery rolls the WHOLE `claimRefund` back: the earlier
    /// call's payout is undone (the mock's counters are real storage and revert with the tx), the leg
    /// stays `Revertable` (not stuck `Reverted`), so the refund remains retryable once the failing call
    /// can be recovered. This is the CEI/atomicity guarantee across a multi-call recovery.
    function test_claimRefund_multiCall_laterRevertRollsBackEarlierPayoutAndState() public {
        MockRecoveryRouter router = _deployMockRouter();
        router.scriptReverts(hex"baad");

        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"600d"); // would recover successfully...
        calls[1] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"baad"); // ...but this one reverts

        InteropBundle memory bundle = _multiCallBundle(calls);
        bytes memory bundleBytes = abi.encode(bundle);
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(bundleBytes);
        manager.forceRevertable(FLOW_ID, bundleHash);

        // Prove BOTH recovery calls are actually reached (so the earlier one genuinely paid out before
        // the later one reverted) — otherwise `recoverSuccesses() == 0` afterwards could be vacuously
        // true because the first call was never made.
        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector, DEST_CHAIN_ID, hex"600d"),
            1
        );
        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector, DEST_CHAIN_ID, hex"baad"),
            1
        );
        vm.expectRevert("recovery boom");
        manager.claimRefund(FLOW_ID, bundleBytes);

        // Everything unwound: the earlier payout is gone and the leg is still claimable.
        assertEq(router.recoverSuccesses(), 0, "the earlier successful recovery must roll back");
        assertEq(
            uint256(manager.legState(FLOW_ID, bundleHash)),
            uint256(LegState.Revertable),
            "the leg must stay Revertable (retryable), not stuck Reverted"
        );
    }
}
