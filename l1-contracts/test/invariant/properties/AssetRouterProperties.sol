// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L1AssetRouterActorHandler} from "../handlers/L1AssetRouterActorHandler.sol";
import {UserActorHandler} from "../handlers/UserActorHandler.sol";
import {L1_TOKEN_ADDRESS} from "../common/Constants.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

abstract contract AssetRouterProperties is Test {
    UserActorHandler[] public userActorHandlers;
    L1AssetRouterActorHandler public l1AssetRouterActorHandler;

    function invariant_TotalDepositsEqualTotalSupply() public {
        address l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);

        uint256 totalSupply;
        if (l2TokenAddress.code.length == 0) {
            totalSupply = 0;
        } else {
            totalSupply = BridgedStandardERC20(l2TokenAddress).totalSupply();
        }

        uint256 totalDepositAmount = l1AssetRouterActorHandler.ghost_totalDeposits();
        for (uint256 i; i < userActorHandlers.length; i++) {
            totalDepositAmount += userActorHandlers[i].ghost_totalWithdrawalAmount();
        }

        assertEq(
            totalDepositAmount,
            totalSupply,
            "total deposit amount must be equal to total supply of all bridged tokens"
        );
    }

    function invariant_L1AssetRouterActorHandlerHasZeroBalance() public {
        address l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);

        if (l2TokenAddress.code.length == 0) {
            return;
        }

        assertEq(
            BridgedStandardERC20(l2TokenAddress).balanceOf(address(l1AssetRouterActorHandler)),
            0,
            "L1AssetRouter must own zero bridged tokens"
        );
    }
}
