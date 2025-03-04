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

import {Token, ActorHandlerAddresses} from "../common/Types.sol";

abstract contract AssetRouterProperties is Test {
    bool initialized;
    Token[] public tokens;
    UserActorHandler[] public userActorHandlers;
    L1AssetRouterActorHandler public l1AssetRouterActorHandler;

    error AlreadyInitialized();

    function initAssetRouterProperties(Token[] memory _tokens, ActorHandlerAddresses memory _actorHandlerAddresses) internal {
        if (initialized) {
            revert AlreadyInitialized();
        }

        for (uint256 i; i < _tokens.length; i++) {
            tokens.push(_tokens[i]);
        }

        for (uint256 i; i < _actorHandlerAddresses.userActorHandlers.length; i++) {
            userActorHandlers.push(UserActorHandler(_actorHandlerAddresses.userActorHandlers[i]));
        }

        l1AssetRouterActorHandler = L1AssetRouterActorHandler(_actorHandlerAddresses.l1AssetRouterActorHandler);

        initialized = true;
    }

    function invariant_TotalDepositsEqualTotalSupply() external {
        assertTrue(initialized);

        uint256 totalSupply;
        for (uint i; i < tokens.length; i++) {
            address l2Token = _getL2Token(tokens[i]);

            if (l2Token.code.length != 0) {
                totalSupply += BridgedStandardERC20(l2Token).totalSupply();
            }
        }

        uint256 totalDepositAmount = l1AssetRouterActorHandler.ghost_totalDeposits();
        for (uint256 i; i < userActorHandlers.length; i++) {
            totalDepositAmount -= userActorHandlers[i].ghost_totalWithdrawalAmount();
        }

        assertEq(
            totalDepositAmount,
            totalSupply,
            "total deposit amount must be equal to total supply of all bridged tokens"
        );
    }

    function invariant_L1AssetRouterActorHandlerHasZeroBalance() external {
        assertTrue(initialized);

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
        assertTrue(initialized);

        IL2NativeTokenVault l2NativeTokenVault = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        for (uint256 i; i < tokens.length; i++) {
            address l2Token = _getL2Token(tokens[i]);

            bytes32 assetId = l2NativeTokenVault.assetId(l2Token);
            uint256 originChainId = l2NativeTokenVault.originChainId(assetId);
            address tokenAddress = l2NativeTokenVault.tokenAddress(assetId);

            // the true branch checks the case when the token has not yet been bridged
            // while the false branch checks the other case
            if (l2Token == address(0) || assetId == bytes32(0) || originChainId == 0 || tokenAddress == address(0)) {
                assertEq(l2Token, address(0), "l2Token is not zero");
                assertEq(assetId, bytes32(0), "assetId is not zero");
                assertEq(originChainId, 0, "originChainId is not zero");
                assertEq(tokenAddress, address(0), "tokenAddress is not zero");
            } else {
                assertNotEq(l2Token, address(0));
                assertNotEq(assetId, bytes32(0));
                assertNotEq(originChainId, 0);
                assertNotEq(tokenAddress, address(0));
            }
        }
    }

    function _getL2Token(Token memory t) internal view returns (address l2Token) {
        if (t.bridged) {
            l2Token = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(t.addr);
        } else {
            l2Token = t.addr;
        }
    }
}
