// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @notice Pins Bridgehub-only authorization after removing the `onlyBridgehubOrEra` exception
/// that admitted `ERA_DIAMOND_PROXY` for `ERA_CHAIN_ID` on base-token deposits.
contract L1AssetRouterAuthTest is Test {
    L1AssetRouter internal router;

    address internal bridgehub = makeAddr("bridgehub");
    address internal originalCaller = makeAddr("originalCaller");

    function setUp() public {
        router = new L1AssetRouter(makeAddr("weth"), bridgehub, makeAddr("nullifier"));
    }

    function test_RevertWhen_NonBridgehubCallsBridgehubDepositBaseToken() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        router.bridgehubDepositBaseToken(271, bytes32("assetId"), originalCaller, 1 ether);
    }

    function test_RevertWhen_NonBridgehubCallsBridgehubDeposit() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        router.bridgehubDeposit(271, originalCaller, 0, hex"");
    }
}
