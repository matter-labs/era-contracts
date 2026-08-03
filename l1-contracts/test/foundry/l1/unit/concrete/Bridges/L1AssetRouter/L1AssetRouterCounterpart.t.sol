// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {AssetDeploymentTrackerNotSet} from "contracts/common/L1ContractErrors.sol";
import {TWO_BRIDGES_MAGIC_VALUE} from "contracts/common/Config.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2TransactionRequestTwoBridgesInner} from "contracts/core/bridgehub/IBridgehubBase.sol";

/// @dev Exposes the internal counterpart-set path + a test-only tracker setter so the counterpart-auth guard
/// can be unit-tested in isolation (the full `bridgehubDeposit` path is covered by the integration suites).
contract L1AssetRouterCounterpartHarness is L1AssetRouter {
    constructor(
        address _weth,
        address _bridgehub,
        address _nullifier,
        uint256 _eraChainId,
        address _eraDiamond
    ) L1AssetRouter(_weth, _bridgehub, _nullifier, _eraChainId, _eraDiamond) {}

    function exposedSetAssetHandlerAddressOnCounterpart(
        uint256 _chainId,
        address _originalCaller,
        bytes32 _assetId,
        address _assetHandlerAddressOnCounterpart
    ) external view returns (L2TransactionRequestTwoBridgesInner memory) {
        return
            _setAssetHandlerAddressOnCounterpart(
                _chainId,
                _originalCaller,
                _assetId,
                _assetHandlerAddressOnCounterpart
            );
    }

    function setTrackerForTest(bytes32 _assetId, address _tracker) external {
        assetDeploymentTracker[_assetId] = _tracker;
    }
}

/// @dev Minimal stand-in tracker: `bridgeCheckCounterpartAddress` is a no-return `view` call, so a registered
/// (nonzero, code-bearing) tracker must let the counterpart-set proceed.
contract MockAssetDeploymentTracker {
    function bridgeCheckCounterpartAddress(uint256, bytes32, address, address) external view {}
}

/// @notice Regression tests for the counterpart-auth guard: `_setAssetHandlerAddressOnCounterpart` must
/// reject an assetId whose
/// `assetDeploymentTracker` is unset (`address(0)`) instead of invoking the no-return counterpart check on a
/// code-less address (which silently succeeds), which would let an unregistered asset's L2 handler be set to
/// an attacker-controlled address.
contract L1AssetRouterCounterpartTest is Test {
    L1AssetRouterCounterpartHarness internal router;

    uint256 internal constant ERA_CHAIN_ID = 270;
    uint256 internal constant DEST_CHAIN_ID = 271;
    address internal caller = makeAddr("caller");
    address internal handlerOnCounterpart = makeAddr("handlerOnCounterpart");

    function setUp() public {
        router = new L1AssetRouterCounterpartHarness(
            makeAddr("weth"),
            makeAddr("bridgehub"),
            makeAddr("nullifier"),
            ERA_CHAIN_ID,
            makeAddr("eraDiamond")
        );
    }

    function test_revertsWhenAssetDeploymentTrackerUnset() external {
        bytes32 assetId = keccak256("unregistered asset");
        assertEq(router.assetDeploymentTracker(assetId), address(0), "precondition: tracker unset");

        vm.expectRevert(abi.encodeWithSelector(AssetDeploymentTrackerNotSet.selector, assetId));
        router.exposedSetAssetHandlerAddressOnCounterpart(DEST_CHAIN_ID, caller, assetId, handlerOnCounterpart);
    }

    function test_succeedsWhenAssetDeploymentTrackerRegistered() external {
        bytes32 assetId = keccak256("registered asset");
        router.setTrackerForTest(assetId, address(new MockAssetDeploymentTracker()));

        L2TransactionRequestTwoBridgesInner memory request = router.exposedSetAssetHandlerAddressOnCounterpart(
            DEST_CHAIN_ID,
            caller,
            assetId,
            handlerOnCounterpart
        );
        assertEq(request.magicValue, TWO_BRIDGES_MAGIC_VALUE);
        assertEq(request.l2Contract, L2_ASSET_ROUTER_ADDR);
    }
}
