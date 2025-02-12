// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L1AssetRouterActorHandler} from "./handlers/L1AssetRouterActorHandler.sol";
import {UserActorHandler} from "./handlers/UserActorHandler.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "../foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";

// TODO: do we need SharedL2ContractDeployer here?
abstract contract AssetRouterProperties is Test, SharedL2ContractDeployer {
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

        uint256 totalDepositAmount = l1AssetRouterActorHandler.totalDeposits();
        for (uint256 i; i < userActorHandlers.length; i++) {
            totalDepositAmount += userActorHandlers[i].totalWithdrawalAmount();
        }

        assertEq(
            totalDepositAmount, totalSupply, "total deposit amount must be equal to total supply of all bridged tokens"
        );
    }

    function invariant_L1AssetRouterActorHandlerHasZeroBalance() public {
        address l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);

        if (l2TokenAddress.code.length == 0) {
            return; // TODO: is it fine to return early here?
        }

        assertEq(
            BridgedStandardERC20(l2TokenAddress).balanceOf(address(l1AssetRouterActorHandler)),
            0,
            "L1AssetRouter must own zero bridged tokens"
        );
    }
}
