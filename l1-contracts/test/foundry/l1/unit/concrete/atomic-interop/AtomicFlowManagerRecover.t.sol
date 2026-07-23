// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {ManagerNoRecoverableCalls} from "contracts/atomic-interop/AtomicInteropErrors.sol";
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
    function exposedRecoverBundle(bytes32 _flowId, bytes32 _bundleHash, InteropBundle memory _bundle) external {
        _recoverBundle(_flowId, _bundleHash, _bundle);
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
/// destination base-token asset id is forwarded, a value leg always counts as recovered, and a fully
/// non-recoverable bundle reverts.
contract AtomicFlowManagerRecoverTest is Test {
    AtomicFlowManagerRecoverHarness internal manager;

    bytes32 internal constant SOURCE_BASE_TOKEN_ASSET_ID = keccak256("source-base-token");
    bytes32 internal constant OTHER_BASE_TOKEN_ASSET_ID = keccak256("other-base-token");

    uint256 internal constant DEST_CHAIN_ID = 271;
    address internal constant DEPOSITOR = address(0xD3903170);
    address internal constant CALL_TARGET = address(0xCA11);

    bytes32 internal constant FLOW_ID = bytes32(uint256(1));
    bytes32 internal constant BUNDLE_HASH = bytes32(uint256(2));

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
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _bundle(SOURCE_BASE_TOKEN_ASSET_ID, value));
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
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _bundle(OTHER_BASE_TOKEN_ASSET_ID, value));
    }

    function test_recoverBundle_revertsWhenDestinationIsL1() public {
        // L2->L1 atomic bundles are rejected at send, so recovery must never process an L1-destined bundle:
        // that keeps it away from the append-only L1 counters in L2AssetTracker (whose settlement-layer
        // updates are only correct at send time). Set L1_CHAIN_ID == the builder's DEST_CHAIN_ID so the bundle
        // is L1-destined, and assert the guard reverts before any refund dispatch.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(DEST_CHAIN_ID);

        vm.expectRevert(RecoverToL1NotSupported.selector);
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _bundle(SOURCE_BASE_TOKEN_ASSET_ID, 5 ether));
    }

    function test_recoverBundle_pureValueCallCountsAsRecovered() public {
        // A value leg whose direct sender has no per-sender recovery must still succeed: the value refund
        // itself counts, so the bundle is not rejected as non-recoverable.
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAssetRouterShared.bridgehubRecoverBaseToken.selector),
            ""
        );

        // Does not revert.
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _bundle(SOURCE_BASE_TOKEN_ASSET_ID, 1 ether));
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

        manager.exposedRecoverBundle(
            FLOW_ID,
            BUNDLE_HASH,
            _bundleFrom(L2_ASSET_ROUTER_ADDR, SOURCE_BASE_TOKEN_ASSET_ID, 1 ether, callData)
        );
    }

    function test_recoverBundle_revertsWhenNothingRecoverable() public {
        // No value and a direct, non-asset-router sender: nothing to reverse, so the refund is rejected.
        vm.expectRevert(abi.encodeWithSelector(ManagerNoRecoverableCalls.selector, FLOW_ID, BUNDLE_HASH));
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _bundle(SOURCE_BASE_TOKEN_ASSET_ID, 0));
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

        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _multiCallBundle(calls));

        assertEq(router.recoverAttempts(), 1, "exactly one router-backed call is asked to recover");
        assertEq(router.recoverSuccesses(), 1, "the router-backed call recovers once");
        assertEq(router.baseTokenRecoveries(), 1, "the direct value leg is refunded once");
    }

    /// @notice A router-backed call that returns `false` (nothing to recover) does not abort the loop: a
    /// LATER recoverable call still succeeds, so the whole bundle counts as recovered and does not revert.
    /// Guards against a regression that treated a `false` as terminal.
    function test_recoverBundle_multiCall_falseThenLaterSuccess() public {
        MockRecoveryRouter router = _deployMockRouter();
        router.scriptReturnsFalse(hex"deed");

        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"deed"); // recoverAtomicCall -> false
        calls[1] = _call(L2_ASSET_ROUTER_ADDR, 0, hex"adad"); // recoverAtomicCall -> true

        // Does not revert (recovered != 0 thanks to the later call).
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _multiCallBundle(calls));

        assertEq(router.recoverAttempts(), 2, "both router-backed calls are attempted");
        assertEq(router.recoverSuccesses(), 1, "only the second call actually recovers");
    }

    /// @notice If EVERY router-backed recovery returns `false`, nothing was recovered: `claimRefund`
    /// reverts `ManagerNoRecoverableCalls`, the leg stays `Revertable`, no `FlowRefunded` is emitted, and
    /// no payout occurs. This is the case a mutant that increments `recovered` regardless of the return
    /// value would slip past (the false-then-true test alone does not catch it, since one call succeeds).
    function test_claimRefund_multiCall_allRouterFalseRevertsAndKeepsRevertable() public {
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

        // The revert discards any FlowRefunded event and all state — so the expectRevert alone proves
        // "no FlowRefunded, no payout"; the post-revert reads below confirm the rollback.
        vm.expectRevert(abi.encodeWithSelector(ManagerNoRecoverableCalls.selector, FLOW_ID, bundleHash));
        manager.claimRefund(FLOW_ID, bundleBytes);

        assertEq(router.recoverAttempts(), 0, "the reverted claim rolls back the attempt tally too");
        assertEq(router.baseTokenRecoveries(), 0, "no base-token payout occurred");
        assertEq(
            uint256(manager.legState(FLOW_ID, bundleHash)),
            uint256(LegState.Revertable),
            "the leg must stay Revertable when nothing was recoverable"
        );
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
