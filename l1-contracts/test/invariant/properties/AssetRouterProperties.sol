// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L1AssetRouterActorHandler} from "../handlers/L1AssetRouterActorHandler.sol";
import {UserActorHandler} from "../handlers/UserActorHandler.sol";
import {L1_TOKEN_ADDRESS} from "../common/Constants.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";

import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

abstract contract AssetRouterProperties is Test {
    UserActorHandler[] public userActorHandlers;
    L1AssetRouterActorHandler public l1AssetRouterActorHandler;

    function invariant_TotalDepositsEqualSupplyPlusWithdrawals() public view {
        address l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);

        uint256 totalSupply;
        if (l2TokenAddress.code.length == 0) {
            totalSupply = 0;
        } else {
            totalSupply = BridgedStandardERC20(l2TokenAddress).totalSupply();
        }

        uint256 totalWithdrawalAmount;
        for (uint256 i; i < userActorHandlers.length; i++) {
            totalWithdrawalAmount += userActorHandlers[i].ghost_totalWithdrawalAmount();
        }

        assertEq(
            l1AssetRouterActorHandler.ghost_totalDeposits(),
            totalSupply + totalWithdrawalAmount,
            "total deposits must equal bridged-token supply plus total withdrawals"
        );
    }

    function invariant_L1AssetRouterActorHandlerHasZeroBalance() public view {
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

    function invariant_HandlersHaveSuccessfulCalls() public view {
        uint256 totalWithdrawalAmount;
        uint256 totalWithdrawalCalls;
        for (uint256 i; i < userActorHandlers.length; i++) {
            totalWithdrawalAmount += userActorHandlers[i].ghost_totalWithdrawalAmount();
            totalWithdrawalCalls += userActorHandlers[i].ghost_totalFunctionCalls();
        }

        assertGt(l1AssetRouterActorHandler.ghost_totalDeposits(), 0, "at least one deposit must succeed");
        assertGt(totalWithdrawalAmount, 0, "at least one withdrawal must succeed");
        assertGt(totalWithdrawalCalls, 0, "the withdrawal handler must record a successful call");
    }
}
