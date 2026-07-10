// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {LegState} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ManagerNoRecoverableCalls} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {
    BundleAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall
} from "contracts/common/Messaging.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

contract AtomicFlowManagerRecoveryHarness is AtomicFlowManager {
    function forceRevertable(bytes32 _flowId, bytes32 _bundleHash) external {
        _state[_flowId][_bundleHash] = LegState.Revertable;
    }
}

contract L2AssetRouterRecoveryHarness is L2AssetRouter {
    address internal immutable manager;
    address internal immutable ntv;

    constructor(address _manager, address _ntv) {
        manager = _manager;
        ntv = _ntv;
    }

    function _atomicFlowManagerAddr() internal view override returns (address) {
        return manager;
    }

    function _nativeTokenVaultAddr() internal view override returns (address) {
        return ntv;
    }

    /// @dev Initializes the inherited reentrancy guard via its real initializer (rather than a storage
    /// override), so `recoverAtomicCall`'s `nonReentrant` modifier is armed for the test.
    function initReentrancyGuardForTest() external reentrancyGuardInitializer {}
}

contract InteropCenterAtomicValidationHarness is InteropCenter {
    function validateAtomicBundle(InteropBundle memory _bundle) external pure {
        _validateAtomicBundle(_bundle);
    }
}

contract MockRecoveringNativeTokenVault {
    uint256 public recoveries;
    uint256 public recoveredDestinationChainId;
    bytes32 public recoveredAssetId;
    address public recoveredOriginalCaller;
    uint256 public recoveredAmount;

    function bridgeRecoverFailedTransfer(uint256 _chainId, bytes32 _assetId, bytes calldata _data) external payable {
        (address originalCaller, , , uint256 amount, ) = DataEncoding.decodeBridgeMintData(_data);
        ++recoveries;
        recoveredDestinationChainId = _chainId;
        recoveredAssetId = _assetId;
        recoveredOriginalCaller = originalCaller;
        recoveredAmount = amount;
    }
}

/// @notice Regression tests for the atomic-interop recovery forgery: an atomic bundle can be committed
/// carrying a `finalizeDeposit` call, but the timeout recovery must only re-credit calls that were
/// produced by the asset router's own burn path (`InteropCall.from == the router`). A direct or otherwise
/// forged call — never backed by a real burn — must not release funds. The NTV is mocked here to isolate
/// the {AtomicFlowManager}/{L2AssetRouter} provenance gate from real vault accounting; reaching the
/// `Revertable` state is short-circuited with a harness (the full send + `authorizeRefund` path is
/// exercised by the anvil-interop suite), since the gate under test is at recovery.
contract AtomicRecoveryForgeryTest is Test {
    AtomicFlowManagerRecoveryHarness internal manager;
    MockRecoveringNativeTokenVault internal ntv;
    L2AssetRouterRecoveryHarness internal router;

    address internal attacker = makeAddr("attacker");
    bytes32 internal assetId = keccak256("existing bridged asset");
    uint256 internal amount = 1_000_000e6;
    uint256 internal destinationChainId = 777;

    function setUp() public {
        manager = new AtomicFlowManagerRecoveryHarness();
        ntv = new MockRecoveringNativeTokenVault();
        router = new L2AssetRouterRecoveryHarness(address(manager), address(ntv));
        router.initReentrancyGuardForTest();
    }

    /// @dev Builds a single-call atomic bundle whose only call is a `finalizeDeposit` to the router,
    /// with the call's `from` set to `_from`. `from` is the sole difference between a genuine
    /// router-produced deposit (`from == router`) and a forged one (`from == attacker`).
    function _buildBundle(address _from) internal returns (InteropBundle memory bundle) {
        bytes memory mintData = DataEncoding.encodeBridgeMintData({
            _originalCaller: attacker,
            _remoteReceiver: attacker,
            _originToken: makeAddr("origin token"),
            _amount: amount,
            _erc20Metadata: bytes("")
        });
        bytes memory callData = abi.encodeWithSelector(
            AssetRouterBase.finalizeDeposit.selector,
            block.chainid,
            assetId,
            mintData
        );

        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: address(router),
            from: _from,
            value: 0,
            data: callData
        });
        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: destinationChainId,
            destinationBaseTokenAssetId: bytes32(uint256(1)),
            interopBundleSalt: keccak256(abi.encodePacked("salt", _from)),
            calls: calls,
            bundleAttributes: BundleAttributes({
                executionAddress: bytes(""),
                unbundlerAddress: bytes(""),
                useFixedFee: false,
                salt: bytes32(0)
            })
        });
    }

    /// @dev Commits the bundle straight to `Revertable` (short-circuiting send + `authorizeRefund`) and
    /// returns the identifiers `claimRefund` needs.
    function _commitRevertable(
        InteropBundle memory _bundle
    ) internal returns (bytes32 flowId, bytes32 bundleHash, bytes memory encodedBundle) {
        encodedBundle = abi.encode(_bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(_bundle.sourceChainId, encodedBundle);
        flowId = keccak256(abi.encodePacked("flow", _bundle.interopBundleSalt));
        manager.forceRevertable(flowId, bundleHash);
    }

    /// A forged, never-burned `finalizeDeposit` (its `from` is the attacker, not the router's own
    /// burn path) is refused on recovery: nothing is recovered, `claimRefund` reverts, the NTV is never
    /// asked to release funds, and the leg stays `Revertable`.
    function test_forgedDirectFinalizeDepositIsRejectedOnRecovery() external {
        InteropBundle memory bundle = _buildBundle(attacker);
        (bytes32 flowId, bytes32 bundleHash, bytes memory encodedBundle) = _commitRevertable(bundle);

        vm.expectRevert(abi.encodeWithSelector(ManagerNoRecoverableCalls.selector, flowId, bundleHash));
        manager.claimRefund(flowId, encodedBundle);

        assertEq(ntv.recoveries(), 0, "forged call must not trigger any recovery");
        assertEq(
            uint256(manager.legState(flowId, bundleHash)),
            uint256(LegState.Revertable),
            "leg must stay Revertable when the forged claim reverts"
        );
    }

    /// A genuine router-produced `finalizeDeposit` (its `from` is the asset router, as set by
    /// `initiateIndirectCall`) still recovers: the NTV reverses the burn with the bundle's mint data and
    /// the leg moves to `Reverted`.
    function test_genuineRouterBackedFinalizeDepositIsRecovered() external {
        InteropBundle memory bundle = _buildBundle(address(router));
        (bytes32 flowId, bytes32 bundleHash, bytes memory encodedBundle) = _commitRevertable(bundle);

        manager.claimRefund(flowId, encodedBundle);

        assertEq(ntv.recoveries(), 1, "router-backed call must recover exactly once");
        assertEq(ntv.recoveredDestinationChainId(), destinationChainId);
        assertEq(ntv.recoveredAssetId(), assetId);
        assertEq(ntv.recoveredOriginalCaller(), attacker);
        assertEq(ntv.recoveredAmount(), amount);
        assertEq(uint256(manager.legState(flowId, bundleHash)), uint256(LegState.Reverted));
    }

    /// The send-time atomic gate only rejects native-`value` legs, so it still admits this (value == 0)
    /// forged bundle. Provenance is deliberately enforced at recovery, not here: committing an unbacked
    /// leg is allowed but inert — it can neither mint on the destination (blocked by the counterpart
    /// check) nor refund on the source (blocked by the recovery provenance gate).
    function test_sendGateStillAdmitsValueZeroForgedBundle() external {
        InteropCenterAtomicValidationHarness center = new InteropCenterAtomicValidationHarness();
        InteropBundle memory bundle = _buildBundle(attacker);
        center.validateAtomicBundle(bundle);
    }
}
