// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicRecoverable} from "contracts/atomic-interop/IAtomicRecoverable.sol";
import {IAssetRouterShared} from "contracts/bridge/asset-router/IAssetRouterShared.sol";
import {L2_ASSET_ROUTER_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {RecoverToL1NotSupported} from "contracts/common/L1ContractErrors.sol";
import {INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION, InteropBundle, InteropCall} from "contracts/common/Messaging.sol";

/// @dev Exposes {AtomicFlowManager._recoverBundle} so its per-call dispatch can be tested in
/// isolation. The Committed -> Revertable -> Reverted machine is driven through the production path in
/// {AtomicFlowManagerRefundTest}; no test forces leg state directly.
contract AtomicFlowManagerRecoverHarness is AtomicFlowManager {
    function exposedRecoverBundle(InteropBundle memory _bundle) external {
        _recoverBundle(_bundle);
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

    function scriptSucceeds(bytes calldata _data) external {
        bytes32 dataHash = keccak256(_data);
        delete returnsFalse[dataHash];
        delete reverts[dataHash];
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

    uint256 internal constant DEST_CHAIN_ID = 271;
    address internal constant DEPOSITOR = address(0xD3903170);
    address internal constant CALL_TARGET = address(0xCA11);

    function setUp() public {
        manager = new AtomicFlowManagerRecoverHarness();
    }

    /// @dev Builds a single direct-call bundle (non-router sender). `destBaseTokenAssetId` selects the
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
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
        });
    }

    /// @dev Dispatch-only (router mocked): a direct value leg's refund is forwarded to
    /// `bridgehubRecoverBaseToken` with the DESTINATION base-token asset id, the depositor, and the value.
    function test_recoverBundle_directValueLeg_forwardsDestinationBaseAssetIdToRouter() public {
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
        // An L1-destined bundle must never be recovered (see {AtomicFlowManager._recoverBundle}); set
        // L1_CHAIN_ID == DEST_CHAIN_ID so the bundle reads as L1-destined.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(DEST_CHAIN_ID);

        vm.expectRevert(RecoverToL1NotSupported.selector);
        manager.exposedRecoverBundle(_bundle(SOURCE_BASE_TOKEN_ASSET_ID, 5 ether));
    }

    function test_recoverBundle_routerBackedValueDoesNotRefundSeparately() public {
        // Indirect (router-produced) calls force `value == 0` at send, so a `from == router` call takes
        // only the recoverAtomicCall branch — never bridgehubRecoverBaseToken (no double refund).
        bytes memory callData = abi.encodeWithSelector(AssetRouterBase.finalizeDeposit.selector);
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeCall(IAtomicRecoverable.recoverAtomicCall, (DEST_CHAIN_ID, callData)),
            abi.encode(true)
        );
        vm.mockCallRevert(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IAssetRouterShared.bridgehubRecoverBaseToken.selector),
            "double recovery"
        );

        // Pin that the router-backed branch is taken: otherwise this passes even if `_recoverBundle`
        // skips both branches.
        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeCall(IAtomicRecoverable.recoverAtomicCall, (DEST_CHAIN_ID, callData))
        );
        manager.exposedRecoverBundle(_bundleFrom(L2_ASSET_ROUTER_ADDR, SOURCE_BASE_TOKEN_ASSET_ID, 1 ether, callData));
    }

    function test_recoverBundle_succeedsWhenNothingRecoverable() public {
        // No value and a direct, non-asset-router sender: nothing to reverse. The refund must still go
        // through (flipping the leg to Reverted is meaningful on its own) and must not touch the asset
        // router at all — both router entry points are set to revert, so any dispatch would fail the
        // test.
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

    // ============ multi-call bundles: every call is processed, none strands the rest ============

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
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
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
}
