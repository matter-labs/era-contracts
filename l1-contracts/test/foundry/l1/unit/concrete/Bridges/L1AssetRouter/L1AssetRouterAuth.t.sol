// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @notice Only the registered L1 Interop Center can submit deposits to the L1 asset router.
contract L1AssetRouterAuthTest is Test {
    uint256 internal constant DEST_CHAIN_ID = 271;

    L1AssetRouter internal router;

    address internal bridgehub = makeAddr("bridgehub");
    address internal interopCenter = makeAddr("interopCenter");
    address internal originalCaller = makeAddr("originalCaller");

    function setUp() public {
        router = new L1AssetRouter(makeAddr("weth"), bridgehub, makeAddr("nullifier"));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.interopCenter, ()), abi.encode(interopCenter));
    }

    function test_RevertWhen_BridgehubCallsBridgehubDepositBaseToken() public {
        vm.prank(bridgehub);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, bridgehub));
        router.bridgehubDepositBaseToken(DEST_CHAIN_ID, bytes32("assetId"), originalCaller, 1 ether);
    }

    function test_RevertWhen_NonInteropCenterCallsBridgehubDepositBaseToken() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        router.bridgehubDepositBaseToken(DEST_CHAIN_ID, bytes32("assetId"), originalCaller, 1 ether);
    }

    /// @dev Pins the removal of the historical `onlyBridgehubOrEra` exception: a chain diamond (formerly
    /// the Era diamond for `ERA_CHAIN_ID`) can no longer deposit the base token directly. Any deployed
    /// diamond that still exposes the legacy `Mailbox.requestL2Transaction` path must be upgraded off it
    /// before the shared router is upgraded to this implementation.
    function test_RevertWhen_ChainDiamondCallsBridgehubDepositBaseTokenDirectly() public {
        address eraDiamond = makeAddr("eraDiamond");
        vm.deal(eraDiamond, 1 ether);

        vm.prank(eraDiamond);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, eraDiamond));
        router.bridgehubDepositBaseToken{value: 1 ether}(DEST_CHAIN_ID, bytes32("assetId"), originalCaller, 1 ether);
    }

    function test_RevertWhen_NonInteropCenterCallsInitiateIndirectCall() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        router.initiateIndirectCall(DEST_CHAIN_ID, originalCaller, 0, hex"");
    }
}
