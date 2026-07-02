// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropBundle, InteropCall, BundleAttributes} from "contracts/common/Messaging.sol";
import {IAssetRouterShared} from "contracts/bridge/asset-router/IAssetRouterShared.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AtomicBundleCallCarriesValue, AtomicBundleCallNotRecoverable} from "contracts/interop/InteropErrors.sol";

/// @notice Test-only harness exposing {InteropCenter}'s internal, `pure` send-time atomic-bundle gate so
/// it can be exercised in isolation, without standing up the full send stack (bridgehub / asset router /
/// value collection). The gate runs on EVERY atomic send (it sits in `_dispatchBundle`, the single funnel
/// for atomic sends), so validating it directly faithfully covers the production path.
contract InteropCenterGateHarness is InteropCenter {
    function exposedValidateAtomicBundleRefundable(InteropBundle memory _bundle) external pure {
        _validateAtomicBundleRefundable(_bundle);
    }
}

/// @notice Send-time refundability gate (`InteropCenter._validateAtomicBundleRefundable`): an atomic bundle
/// is refundable-by-construction iff every call carries no native base-token `value` and is a recoverable
/// asset-router `finalizeDeposit` call. These tests assert the gate accepts a well-formed bundle and
/// rejects native-value, wrong-target, wrong-selector, and mixed bundles — so a non-refundable leg can
/// never commit (spec property P3).
contract AtomicSendGateTest is Test {
    InteropCenterGateHarness internal gate;

    uint256 internal constant DEST_CHAIN_ID = 272;
    bytes32 internal constant ASSET_ID = bytes32(uint256(0xA55E7));
    bytes32 internal constant BASE_TOKEN_ASSET_ID = bytes32(uint256(0xBA5E));

    function setUp() public {
        gate = new InteropCenterGateHarness();
    }

    /// @dev A recoverable call: `finalizeDeposit(chainId, assetId, transferData)` to the canonical asset
    /// router, carrying no native value.
    function _recoverableCall() internal pure returns (InteropCall memory) {
        bytes memory data = abi.encodeWithSelector(
            IAssetRouterShared.finalizeDeposit.selector,
            uint256(271),
            ASSET_ID,
            bytes("")
        );
        return
            InteropCall({
                version: bytes1(0x01),
                shadowAccount: false,
                to: L2_ASSET_ROUTER_ADDR,
                from: address(1),
                value: 0,
                data: data
            });
    }

    /// @dev Assemble a bundle around a set of calls.
    function _bundle(InteropCall[] memory _calls) internal pure returns (InteropBundle memory) {
        return
            InteropBundle({
                version: bytes1(0x01),
                sourceChainId: 271,
                destinationChainId: DEST_CHAIN_ID,
                destinationBaseTokenAssetId: BASE_TOKEN_ASSET_ID,
                interopBundleSalt: bytes32(0),
                calls: _calls,
                bundleAttributes: BundleAttributes({executionAddress: "", unbundlerAddress: "", useFixedFee: false})
            });
    }

    function test_sendGate_acceptsRecoverableBundle() public view {
        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = _recoverableCall();
        calls[1] = _recoverableCall();
        // No revert == accepted (the call IS the assertion).
        gate.exposedValidateAtomicBundleRefundable(_bundle(calls));
    }

    function test_sendGate_rejectsNativeValueCall() public {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = _recoverableCall();
        calls[0].value = 1; // native base-token value -> not recoverable on timeout
        vm.expectRevert(abi.encodeWithSelector(AtomicBundleCallCarriesValue.selector, uint256(0), uint256(1)));
        gate.exposedValidateAtomicBundleRefundable(_bundle(calls));
    }

    function test_sendGate_rejectsNonAssetRouterTarget() public {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = _recoverableCall();
        address stranger = makeAddr("stranger");
        calls[0].to = stranger; // finalizeDeposit selector but not the canonical asset router
        vm.expectRevert(abi.encodeWithSelector(AtomicBundleCallNotRecoverable.selector, uint256(0), stranger));
        gate.exposedValidateAtomicBundleRefundable(_bundle(calls));
    }

    function test_sendGate_rejectsWrongSelector() public {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = _recoverableCall();
        calls[0].data = hex"deadbeef"; // asset router target but not a finalizeDeposit call
        vm.expectRevert(
            abi.encodeWithSelector(AtomicBundleCallNotRecoverable.selector, uint256(0), L2_ASSET_ROUTER_ADDR)
        );
        gate.exposedValidateAtomicBundleRefundable(_bundle(calls));
    }

    function test_sendGate_rejectsMixedBundle() public {
        // A mixed bundle: one recoverable call, one non-recoverable call. The whole bundle is rejected at
        // the offending index (no partial commit that could strand the uncovered call on timeout).
        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = _recoverableCall();
        calls[1] = _recoverableCall();
        calls[1].data = hex"00112233"; // wrong selector
        vm.expectRevert(
            abi.encodeWithSelector(AtomicBundleCallNotRecoverable.selector, uint256(1), L2_ASSET_ROUTER_ADDR)
        );
        gate.exposedValidateAtomicBundleRefundable(_bundle(calls));
    }
}
