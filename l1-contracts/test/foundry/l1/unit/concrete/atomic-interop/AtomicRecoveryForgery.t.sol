// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {LegState} from "contracts/atomic-interop/IAtomicInterop.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IAtomicRecoverable} from "contracts/atomic-interop/IAtomicRecoverable.sol";
import {AssetHandlerDoesNotExist, RecoverToL1NotSupported, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION, InteropBundle, InteropCall} from "contracts/common/Messaging.sol";
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

    /// @dev Registers an asset handler directly. In production the mapping is populated by the burn
    /// itself (`_burn` / `tryRegisterTokenFromBurnData`); the harness short-circuits that since these
    /// tests start from an already-Revertable leg and never run the send path.
    function setAssetHandlerForTest(bytes32 _assetId, address _handler) external {
        _setAssetHandler(_assetId, _handler);
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

/// @notice Regression tests for the atomic-recovery forgery: on timeout recovery only calls produced by
/// the asset router's own burn path (`InteropCall.from == L2_ASSET_ROUTER_ADDR`) may be re-credited;
/// forged direct calls are skipped. See {protocol-docs/bridging.md#atomic-recovery-hook}.
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
        // Recovery routes through the handler registered for the asset at burn time; the burn is
        // short-circuited in these tests, so register the mock vault as the asset's handler explicitly.
        router.setAssetHandlerForTest(assetId, address(ntv));
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
        bytes memory callData = abi.encodeCall(AssetRouterBase.finalizeDeposit, (block.chainid, assetId, mintData));

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
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
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

    // Recovery side (AtomicFlowManager._recoverBundle skips `from != L2_ASSET_ROUTER_ADDR`)

    /// A forged, never-burned `finalizeDeposit` (its `from` is the attacker, not the router's burn path) is
    /// skipped on recovery: the NTV is never asked to release funds. The claim itself still goes through —
    /// a bundle with nothing recoverable simply flips to `Reverted` without moving funds.
    function test_forgedDirectFinalizeDepositIsSkippedOnRecovery() external {
        InteropBundle memory bundle = _buildBundle({_from: attacker, _to: address(router)});
        (bytes32 flowId, bytes32 bundleHash, bytes memory encodedBundle) = _commitRevertable(bundle);

        manager.claimRefund(flowId, encodedBundle);

        assertEq(ntv.recoveries(), 0, "forged call must not trigger any recovery");
        assertEq(
            uint256(manager.legState(flowId, bundleHash)),
            uint256(LegState.Reverted),
            "the no-op claim still consumes the leg"
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

    /// Recovery must reverse the burn through the SAME handler that performed it: a bridged asset whose
    /// burns run through a custom (non-NTV) asset handler is recovered through that handler, and the
    /// NTV is never consulted.
    function test_recoveryRoutesThroughRegisteredCustomAssetHandler() external {
        MockRecoveringNativeTokenVault customHandler = new MockRecoveringNativeTokenVault();
        router.setAssetHandlerForTest(assetId, address(customHandler));

        InteropBundle memory bundle = _buildBundle({_from: L2_ASSET_ROUTER_ADDR, _to: address(router)});
        (bytes32 flowId, bytes32 bundleHash, bytes memory encodedBundle) = _commitRevertable(bundle);

        manager.claimRefund(flowId, encodedBundle);

        assertEq(customHandler.recoveries(), 1, "burn must be reversed by its own handler");
        assertEq(customHandler.recoveredAssetId(), assetId);
        assertEq(customHandler.recoveredOriginalCaller(), attacker);
        assertEq(customHandler.recoveredAmount(), amount);
        assertEq(ntv.recoveries(), 0, "the NTV must not be consulted for a custom-handled asset");
        assertEq(uint256(manager.legState(flowId, bundleHash)), uint256(LegState.Reverted));
    }

    /// A genuine burn always leaves its handler registered, so a missing registration means the call
    /// cannot be safely recovered — the claim reverts instead of guessing a handler.
    function test_recoveryRevertsWhenAssetHandlerNotRegistered() external {
        bytes32 unregisteredAssetId = keccak256("never burned through this router");
        assetId = unregisteredAssetId;

        InteropBundle memory bundle = _buildBundle({_from: L2_ASSET_ROUTER_ADDR, _to: address(router)});
        (bytes32 flowId, bytes32 bundleHash, bytes memory encodedBundle) = _commitRevertable(bundle);

        vm.expectRevert(abi.encodeWithSelector(AssetHandlerDoesNotExist.selector, unregisteredAssetId));
        manager.claimRefund(flowId, encodedBundle);

        assertEq(ntv.recoveries(), 0);
        assertEq(
            uint256(manager.legState(flowId, bundleHash)),
            uint256(LegState.Revertable),
            "leg must stay Revertable when the claim reverts"
        );
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
            keccak256("base token asset id"),
            makeAddr("aliased owner")
        );
    }

    // L2AssetRouter.recoverAtomicCall entry-point surface (the recovery collaborator, called directly)

    /// @notice `recoverAtomicCall` is gated to the atomic flow manager: any other caller is rejected
    /// with `Unauthorized`, so nobody can drive a recovery (a re-mint) outside the timeout flow.
    function test_recoverAtomicCall_RevertWhen_callerNotManager() external {
        bytes memory callData = abi.encodeWithSelector(AssetRouterBase.finalizeDeposit.selector);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        IAtomicRecoverable(L2_ASSET_ROUTER_ADDR).recoverAtomicCall(destinationChainId, callData);
    }

    /// @notice A manager-issued call whose data is too short to carry a selector recovers nothing:
    /// `recoverAtomicCall` returns `false` and never touches the NTV. This is the "not a recoverable
    /// call" branch — it must be a no-op, not a revert, so a mixed bundle's other calls can still
    /// recover (see {AtomicFlowManager._recoverBundle}).
    function test_recoverAtomicCall_managerShortData_returnsFalseAndDoesNotRecover() external {
        vm.prank(address(manager));
        bool recovered = IAtomicRecoverable(L2_ASSET_ROUTER_ADDR).recoverAtomicCall(destinationChainId, hex"00");
        assertFalse(recovered, "sub-selector data must not recover");
        assertEq(ntv.recoveries(), 0, "the NTV must be untouched");
    }

    /// @notice ...and a manager-issued call whose selector is not `finalizeDeposit` is likewise a
    /// no-op `false` — only asset-router deposit calls are reversible.
    function test_recoverAtomicCall_managerWrongSelector_returnsFalseAndDoesNotRecover() external {
        bytes memory wrongSelectorData = abi.encodeWithSelector(bytes4(keccak256("notFinalizeDeposit()")), uint256(1));
        vm.prank(address(manager));
        bool recovered = IAtomicRecoverable(L2_ASSET_ROUTER_ADDR).recoverAtomicCall(
            destinationChainId,
            wrongSelectorData
        );
        assertFalse(recovered, "a non-finalizeDeposit selector must not recover");
        assertEq(ntv.recoveries(), 0, "the NTV must be untouched");
    }
}
