// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";

import {Token} from "../common/Types.sol";
import {ActorHandler} from "./ActorHandler.sol";

contract UserActorHandler is ActorHandler {
    mapping(address => bool) public ghost_tokenRegisteredWithL2NativeTokenVault;
    uint256 public ghost_totalWithdrawalAmount;
    uint256 public ghost_totalFunctionCalls;

    constructor(Token[] memory _tokens) ActorHandler(_tokens) {}

    function withdrawV1(uint256 _amount, address _receiver, uint256 _tokenIndex) external {
        uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

        (address l1Token, address l2Token) = _getL1TokenAndL2Token(tokens[tokenIndex]);

        vm.assume(l2Token.code.length != 0);
        uint256 balance = BridgedStandardERC20(l2Token).balanceOf(address(this));
        vm.assume(balance > 0);
        uint256 amount = bound(_amount, 1, balance);

        l2SharedBridge.withdraw(_receiver, l2Token, amount);

        ghost_totalWithdrawalAmount += amount;
    }

    function withdraw(uint256 _amount, address _receiver, uint256 _tokenIndex) external {
        uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

        (address l1Token, address l2Token) = _getL1TokenAndL2Token(tokens[tokenIndex]);

        uint256 amount;
        if (ghost_totalFunctionCalls % 10 == 0 && false) {
            amount = _amount;
        } else {
            vm.assume(l2Token.code.length != 0);
            uint256 balance = BridgedStandardERC20(l2Token).balanceOf(address(this));
            vm.assume(balance > 0);
            amount = bound(_amount, 1, balance);
        }

        l2AssetRouter.withdraw(_receiver, l2Token, amount);

        ghost_totalWithdrawalAmount += amount;
        ghost_totalFunctionCalls++;
    }

    function withdrawV2(uint256 _amount, address _receiver, uint256 _tokenIndex) external {
        uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

        (address l1Token, address l2Token) = _getL1TokenAndL2Token(tokens[tokenIndex]);

        // without bounding the amount the handler usually tries to withdraw more than it has causing reverts
        // on the other hand we do want to test for "withdraw more than one has" cases
        // by bounding the amount for _some_ withdrawals we balance between having too many useless reverts
        // and testing too few cases
        uint256 amount;
        if (ghost_totalFunctionCalls % 10 == 0 && false) {
            amount = _amount;
        } else {
            vm.assume(l2Token.code.length != 0);
            amount = bound(_amount, 0, BridgedStandardERC20(l2Token).balanceOf(address(this)));
        }

        // too many reverts (around 50%) without this condition
        vm.assume(amount != 0);
        // using `L2NativeTokenVault` instead of `IL2NativeTokenVault` because the latter doesn't have `L2_LEGACY_SHARED_BRIDGE`
        vm.assume(l2NativeTokenVault.L2_LEGACY_SHARED_BRIDGE().l1TokenAddress(l2Token) != address(0));


        uint256 l1ChainId = l2AssetRouter.L1_CHAIN_ID();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, l1Token);
        bytes memory data = DataEncoding.encodeBridgeBurnData(amount, _receiver, l2Token);

        l2AssetRouter.withdraw(assetId, data);

        ghost_totalWithdrawalAmount += amount;
        ghost_totalFunctionCalls++;
    }

    function registerTokenWithVault(uint256 _tokenIndex) external {
        uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

        (address l1Token, address l2Token) = _getL1TokenAndL2Token(tokens[tokenIndex]);

        vm.assume(l2SharedBridge.l1TokenAddress(l2Token) != address(0));
        vm.assume(l2AssetRouter.l1TokenAddress(l2Token) == address(0));

        if (ghost_tokenRegisteredWithL2NativeTokenVault[l2Token]) {
            return;
        }

        l2NativeTokenVault.setLegacyTokenAssetId(l2Token);

        ghost_tokenRegisteredWithL2NativeTokenVault[l2Token] = true;
    }

    function registerTokenWithVaultV2(uint256 _tokenIndex) external {
        uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

        (address l1Token, address l2Token) = _getL1TokenAndL2Token(tokens[tokenIndex]);

        vm.assume(l2Token.code.length != 0);
        vm.assume(l2SharedBridge.l1TokenAddress(l2Token) == address(0));
        vm.assume(l2AssetRouter.l1TokenAddress(l2Token) == address(0));

        if (ghost_tokenRegisteredWithL2NativeTokenVault[l2Token]) {
            return;
        }
        
        l2NativeTokenVault.registerToken(l2Token);

        ghost_tokenRegisteredWithL2NativeTokenVault[l2Token] = true;
    }

    // function registerTokenWithVaultV2(uint256 _tokenIndex) external {
    //     uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

    //     address l1Token = tokens[tokenIndex];
    //     address l2Token = l2AssetRouter.l2TokenAddress(l1Token);
    //     bytes memory d = DataEncoding.encodeBridgeBurnData(0, address(0), l2Token);
    //     bytes32
    // }
}
