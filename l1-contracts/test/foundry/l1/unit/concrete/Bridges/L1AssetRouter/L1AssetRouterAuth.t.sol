// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @notice Only Bridgehub can submit deposits to the L1 asset router.
contract L1AssetRouterAuthTest is Test {
    uint256 internal constant DEST_CHAIN_ID = 271;

    L1AssetRouter internal router;

    address internal bridgehub = makeAddr("bridgehub");
    address internal originalCaller = makeAddr("originalCaller");

    function setUp() public {
        router = new L1AssetRouter(makeAddr("weth"), bridgehub, makeAddr("nullifier"));
    }

    function test_RevertWhen_NonBridgehubCallsBridgehubDepositBaseToken() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        router.bridgehubDepositBaseToken(DEST_CHAIN_ID, bytes32("assetId"), originalCaller, 1 ether);
    }

    function test_RevertWhen_NonBridgehubCallsBridgehubDeposit() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        router.bridgehubDeposit(DEST_CHAIN_ID, originalCaller, 0, hex"");
    }
}
