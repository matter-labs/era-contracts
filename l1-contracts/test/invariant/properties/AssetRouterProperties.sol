// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {LegacyBridgeActorHandler} from "../handlers/LegacyBridgeActorHandler.sol";
import {L1AssetRouterActorHandler} from "../handlers/L1AssetRouterActorHandler.sol";
import {UserActorHandler} from "../handlers/UserActorHandler.sol";
import {L1_TOKEN_ADDRESS} from "../common/Constants.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";

abstract contract AssetRouterProperties is Test {
    address[] public l1Tokens;
    UserActorHandler[] public userActorHandlers;
    LegacyBridgeActorHandler public legacyBridgeActorHandler;
    L1AssetRouterActorHandler public l1AssetRouterActorHandler;

    function invariant_TotalDepositsEqualTotalSupply() external {
        address l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);

        uint256 totalSupply;
        if (l2TokenAddress.code.length == 0) {
            totalSupply = 0;
        } else {
            totalSupply = BridgedStandardERC20(l2TokenAddress).totalSupply();
        }

        uint256 totalDepositAmount = l1AssetRouterActorHandler.ghost_totalDeposits() +
            legacyBridgeActorHandler.ghost_totalDeposits();
        for (uint256 i; i < userActorHandlers.length; i++) {
            totalDepositAmount += userActorHandlers[i].ghost_totalWithdrawalAmount();
        }

        assertEq(
            totalDepositAmount,
            totalSupply,
            "total deposit amount must be equal to total supply of all bridged tokens"
        );
    }

    function invariant_L1AssetRouterActorHandlerHasZeroBalance() external {
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

    function invariant_BridgedTokensConfiguredCorrectly() external {
        IL2NativeTokenVault l2NativeTokenVault = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        for (uint256 i; i < l1Tokens.length; i++) {
            address l2Token = l2NativeTokenVault.l2TokenAddress(l1Tokens[i]);

            bytes32 assetId = l2NativeTokenVault.assetId(l2Token);
            uint256 originChainId = l2NativeTokenVault.originChainId(assetId);
            address tokenAddress = l2NativeTokenVault.tokenAddress(assetId);

            // the true branch checks the case when the token has not yet been bridged
            // while the false branch checks the other case
            if (l2Token == address(0) || assetId == bytes32(0) || originChainId == 0 || tokenAddress == address(0)) {
                assertEq(l2Token, address(0));
                assertEq(assetId, bytes32(0));
                assertEq(originChainId, 0);
                assertEq(tokenAddress, address(0));
            } else {
                assertNotEq(l2Token, address(0));
                assertNotEq(assetId, bytes32(0));
                assertNotEq(originChainId, 0);
                assertNotEq(tokenAddress, address(0));
            }
        }
    }
}
