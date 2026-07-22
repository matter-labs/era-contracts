// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {LegState} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ManagerNoRecoverableCalls} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {RecoverToL1NotSupported, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    BundleAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall
} from "contracts/common/Messaging.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2_ASSET_ROUTER_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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

/// @notice Regression tests for the atomic-recovery forgery: on timeout recovery only calls produced by
/// the asset router's own burn path (`InteropCall.from == L2_ASSET_ROUTER_ADDR`) may be re-credited;
/// forged direct calls are skipped. See {protocol-docs/bridging.md}.
/// @dev The NTV is mocked to isolate the provenance gate from real vault accounting; `Revertable` state
/// is forced via a harness (the full send + `authorizeRefund` proof path is covered by the anvil-interop
/// suite) since the gate under test is at recovery.
contract AtomicRecoveryForgeryTest is Test {
    uint256 internal constant L1_CHAIN_ID = 1;
    uint256 internal constant ERA_CHAIN_ID = 271;

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
        // Recovery dispatches to each call's local sender (`InteropCall.from`) — for burn-produced calls
        // the canonical L2_ASSET_ROUTER_ADDR — so the router harness must live at that address.
        deployCodeTo(
            "AtomicRecoveryForgery.t.sol:L2AssetRouterRecoveryHarness",
            abi.encode(address(manager), address(ntv)),
            L2_ASSET_ROUTER_ADDR
        );
        router = L2AssetRouterRecoveryHarness(L2_ASSET_ROUTER_ADDR);
        router.initReentrancyGuardForTest();
    }

    /// @dev Builds a single-call atomic bundle whose only call is a `finalizeDeposit`, with the call's
    /// `from`/`to` set to the given values. `from` is the provenance discriminator (`L2_ASSET_ROUTER_ADDR`
    /// iff produced by the router's own burn path) and the recovery target; `to` is the destination-side
    /// counterpart, never called during recovery.
    function _buildBundle(address _from, address _to) internal returns (InteropBundle memory bundle) {
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
            to: _to,
            from: _from,
            value: 0,
            data: callData
        });
        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: destinationChainId,
            destinationBaseTokenAssetId: bytes32(uint256(1)),
            interopBundleSalt: keccak256(abi.encodePacked("salt", _from, _to)),
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
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(encodedBundle);
        flowId = keccak256(abi.encodePacked("flow", _bundle.interopBundleSalt));
        manager.forceRevertable(flowId, bundleHash);
    }

    // ---------------------------------------------------------------------------------------------
    // Recovery side (AtomicFlowManager._recoverBundle skips `from != L2_ASSET_ROUTER_ADDR`)
    // ---------------------------------------------------------------------------------------------

    /// A forged, never-burned `finalizeDeposit` (its `from` is the attacker, not the router's burn path) is
    /// skipped on recovery: nothing is recovered, `claimRefund` reverts, the NTV is never asked to release
    /// funds, and the leg stays `Revertable`.
    function test_forgedDirectFinalizeDepositIsRejectedOnRecovery() external {
        InteropBundle memory bundle = _buildBundle({_from: attacker, _to: address(router)});
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

    /// A genuine router-produced `finalizeDeposit` (its `from` is `L2_ASSET_ROUTER_ADDR`, as set by
    /// `initiateIndirectCall`) still recovers: the NTV reverses the burn with the bundle's mint data and the
    /// leg moves to `Reverted`.
    function test_genuineRouterBackedFinalizeDepositIsRecovered() external {
        InteropBundle memory bundle = _buildBundle({_from: L2_ASSET_ROUTER_ADDR, _to: address(router)});
        (bytes32 flowId, bytes32 bundleHash, bytes memory encodedBundle) = _commitRevertable(bundle);

        manager.claimRefund(flowId, encodedBundle);

        assertEq(ntv.recoveries(), 1, "router-backed call must recover exactly once");
        assertEq(ntv.recoveredDestinationChainId(), destinationChainId);
        assertEq(ntv.recoveredAssetId(), assetId);
        assertEq(ntv.recoveredOriginalCaller(), attacker);
        assertEq(ntv.recoveredAmount(), amount);
        assertEq(uint256(manager.legState(flowId, bundleHash)), uint256(LegState.Reverted));
    }

    /// A timed-out value leg is recovered through the asset router wrapper: the wrapper reconstructs
    /// bridge-mint data for the original depositor and forwards it to the NTV failed-transfer path.
    function test_bridgehubRecoverBaseTokenForwardsRecoveryToNativeTokenVault() external {
        vm.prank(address(manager));
        router.bridgehubRecoverBaseToken(destinationChainId, assetId, attacker, amount);

        assertEq(ntv.recoveries(), 1, "value-leg recovery must reach the NTV exactly once");
        assertEq(ntv.recoveredDestinationChainId(), destinationChainId);
        assertEq(ntv.recoveredAssetId(), assetId);
        assertEq(ntv.recoveredOriginalCaller(), attacker);
        assertEq(ntv.recoveredAmount(), amount);
    }

    function test_bridgehubRecoverBaseToken_revertsFromNonManager() external {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, attacker));
        vm.prank(attacker);
        router.bridgehubRecoverBaseToken(destinationChainId, assetId, attacker, amount);
    }

    function test_bridgehubRecoverBaseToken_revertsForL1Destination() external {
        _initializeRouterChainIds();

        vm.expectRevert(RecoverToL1NotSupported.selector);
        vm.prank(address(manager));
        router.bridgehubRecoverBaseToken(L1_CHAIN_ID, assetId, attacker, amount);
    }

    /// L2->L1 interop is never revertable (rejected at send), so recovery asserts the invariant: even a
    /// genuine router-backed burn reverts wholesale when destined to L1 — leaving the leg `Revertable`
    /// instead of unwinding the append-only `totalWithdrawalsToL1` accounting.
    function test_recoverToL1IsUnreachable() external {
        // Arm the router's L1 chain id through the real upgrade entry point.
        _initializeRouterChainIds();

        InteropBundle memory bundle = _buildBundle({_from: L2_ASSET_ROUTER_ADDR, _to: address(router)});
        bundle.destinationChainId = L1_CHAIN_ID;
        (bytes32 flowId, bytes32 bundleHash, bytes memory encodedBundle) = _commitRevertable(bundle);

        vm.expectRevert(RecoverToL1NotSupported.selector);
        manager.claimRefund(flowId, encodedBundle);

        assertEq(ntv.recoveries(), 0, "an L1-destined burn must never reach the NTV recovery path");
        assertEq(
            uint256(manager.legState(flowId, bundleHash)),
            uint256(LegState.Revertable),
            "leg must stay Revertable when the L1-destined claim reverts"
        );
    }

    function _initializeRouterChainIds() internal {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        // solhint-disable-next-line func-named-parameters
        router.updateL2(
            L1_CHAIN_ID,
            ERA_CHAIN_ID,
            IL1AssetRouter(makeAddr("l1 asset router")),
            IL2SharedBridgeLegacy(address(0)),
            keccak256("base token asset id"),
            makeAddr("aliased owner")
        );
    }
}
