// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {ManagerNoRecoverableCalls} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IAtomicRecoverable} from "contracts/atomic-interop/IAtomicRecoverable.sol";
import {IAssetRouterShared} from "contracts/bridge/asset-router/IAssetRouterShared.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    BundleAttributes,
    InteropBundle,
    InteropCall,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION
} from "contracts/common/Messaging.sol";

/// @dev Exposes the internal {AtomicFlowManager._recoverBundle} so its value-refund dispatch can be unit
/// tested in isolation (the surrounding Committed->Revertable->Reverted state machine is exercised by the
/// atomic-interop anvil spec end-to-end).
contract AtomicFlowManagerRecoverHarness is AtomicFlowManager {
    function exposedRecoverBundle(bytes32 _flowId, bytes32 _bundleHash, InteropBundle memory _bundle) external {
        _recoverBundle(_flowId, _bundleHash, _bundle);
    }
}

/// @notice Unit tests for the native-value refund branch added to {AtomicFlowManager._recoverBundle}.
/// The external collaborators (NTV base-token asset id, per-target recovery, BaseTokenHolder refund, asset
/// router recover) are mocked so we assert purely the dispatch logic: same-vs-different base token routing,
/// that a value leg always counts as recovered, and that a fully non-recoverable bundle reverts.
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

        // The source chain's base token asset id, read in _recoverBundle to choose the refund path.
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.BASE_TOKEN_ASSET_ID.selector),
            abi.encode(SOURCE_BASE_TOKEN_ASSET_ID)
        );
    }

    /// @dev Builds a single-call bundle. `destBaseTokenAssetId` selects the refund path; `value` marks it
    /// as a value-carrying leg.
    function _bundle(bytes32 _destBaseTokenAssetId, uint256 _value) internal view returns (InteropBundle memory b) {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: CALL_TARGET,
            from: DEPOSITOR,
            value: _value,
            data: ""
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

    /// @dev Makes the call target report "no per-target recovery", isolating the value-refund branch.
    function _mockTargetNotRecoverable() internal {
        vm.mockCall(
            CALL_TARGET,
            abi.encodeWithSelector(IAtomicRecoverable.recoverAtomicCall.selector),
            abi.encode(false)
        );
    }

    function test_recoverBundle_sameBaseToken_refundsViaBaseTokenHolder() public {
        _mockTargetNotRecoverable();
        // Destination shares this chain's base token -> refund is routed through the BaseTokenHolder.
        vm.mockCall(
            L2_BASE_TOKEN_HOLDER_ADDR,
            abi.encodeWithSelector(IBaseTokenHolder.refundBridgedBaseToken.selector),
            ""
        );

        uint256 value = 5 ether;
        vm.expectCall(
            L2_BASE_TOKEN_HOLDER_ADDR,
            abi.encodeCall(IBaseTokenHolder.refundBridgedBaseToken, (DEPOSITOR, value, DEST_CHAIN_ID))
        );
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _bundle(SOURCE_BASE_TOKEN_ASSET_ID, value));
    }

    function test_recoverBundle_differentBaseToken_refundsViaAssetRouter() public {
        _mockTargetNotRecoverable();
        // Destination base token differs -> refund reverses the asset-router base-token deposit, re-crediting
        // the *destination* base-token asset to the depositor.
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

    function test_recoverBundle_pureValueCallCountsAsRecovered() public {
        // A value leg whose target reports no per-target recovery must still succeed: the value refund
        // itself counts, so the bundle is not rejected as non-recoverable.
        _mockTargetNotRecoverable();
        vm.mockCall(
            L2_BASE_TOKEN_HOLDER_ADDR,
            abi.encodeWithSelector(IBaseTokenHolder.refundBridgedBaseToken.selector),
            ""
        );

        // Does not revert.
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _bundle(SOURCE_BASE_TOKEN_ASSET_ID, 1 ether));
    }

    function test_recoverBundle_revertsWhenNothingRecoverable() public {
        // No value and an unrecognised target: nothing to reverse, so the refund is rejected.
        _mockTargetNotRecoverable();
        vm.expectRevert(abi.encodeWithSelector(ManagerNoRecoverableCalls.selector, FLOW_ID, BUNDLE_HASH));
        manager.exposedRecoverBundle(FLOW_ID, BUNDLE_HASH, _bundle(SOURCE_BASE_TOKEN_ASSET_ID, 0));
    }
}
