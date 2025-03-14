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

    function withdrawV0(uint256 _amount, address _receiver, uint256 _tokenIndex) external {
        (, address l2Token) = _boundTokenIndexAndGetTokenAddresses(_tokenIndex);
        uint256 amount = _boundAmountAndAssumeBalance(_amount, l2Token);

        l2SharedBridge.withdraw(_receiver, l2Token, amount);

        ghost_totalWithdrawalAmount += amount;
        ghost_totalFunctionCalls++;
    }

    function withdrawV1(uint256 _amount, address _receiver, uint256 _tokenIndex) external {
        (, address l2Token) = _boundTokenIndexAndGetTokenAddresses(_tokenIndex);
        uint256 amount = _boundAmountAndAssumeBalance(_amount, l2Token);

        l2AssetRouter.withdraw(_receiver, l2Token, amount);

        ghost_totalWithdrawalAmount += amount;
        ghost_totalFunctionCalls++;
    }

    function withdrawV2(uint256 _amount, address _receiver, uint256 _tokenIndex) external {
        (address l1Token, address l2Token) = _boundTokenIndexAndGetTokenAddresses(_tokenIndex);
        uint256 amount = _boundAmountAndAssumeBalance(_amount, l2Token);

        _assumeRegisteredWithL2SharedBridge(l2Token);

        uint256 l1ChainId = l2AssetRouter.L1_CHAIN_ID();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, l1Token);
        bytes memory data = DataEncoding.encodeBridgeBurnData(amount, _receiver, l2Token);

        l2AssetRouter.withdraw(assetId, data);

        ghost_totalWithdrawalAmount += amount;
        ghost_totalFunctionCalls++;
    }

    function registerTokenWithVaultV0(uint256 _tokenIndex) external {
        (, address l2Token) = _boundTokenIndexAndGetTokenAddresses(_tokenIndex);

        _assumeRegisteredWithL2SharedBridge(l2Token);
        _assumeNotRegisteredWithNativeTokenVault(l2Token);

        if (ghost_tokenRegisteredWithL2NativeTokenVault[l2Token]) {
            return;
        }

        l2NativeTokenVault.setLegacyTokenAssetId(l2Token);

        ghost_tokenRegisteredWithL2NativeTokenVault[l2Token] = true;
    }

    function registerTokenWithVaultV1(uint256 _tokenIndex) external {
        (, address l2Token) = _boundTokenIndexAndGetTokenAddresses(_tokenIndex);

        _assumeNotRegistered(l2Token);
        _assumeHasCodeAndNotWeth(l2Token);

        if (ghost_tokenRegisteredWithL2NativeTokenVault[l2Token]) {
            return;
        }

        l2NativeTokenVault.registerToken(l2Token);

        ghost_tokenRegisteredWithL2NativeTokenVault[l2Token] = true;
    }

    function registerTokenWithVaultV2(uint256 _tokenIndex) external {
        (, address l2Token) = _boundTokenIndexAndGetTokenAddresses(_tokenIndex);

        _assumeNotRegistered(l2Token);
        _assumeHasCodeAndNotWeth(l2Token);

        l2NativeTokenVault.ensureTokenIsRegistered(l2Token);

        ghost_tokenRegisteredWithL2NativeTokenVault[l2Token] = true;
    }

    function registerTokenWithVaultV3(uint256 _tokenIndex) external {
        uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

        (address l1Token, address l2Token) = _getL1TokenAndL2Token(tokens[tokenIndex]);

        Token memory token = tokens[tokenIndex];
        bytes memory d = DataEncoding.encodeBridgeBurnData(0, address(0), l2Token);
        uint256 chainid;
        bytes32 expectedAssetId;
        if (token.bridged) {
            chainid = l2AssetRouter.L1_CHAIN_ID();
            expectedAssetId = DataEncoding.encodeNTVAssetId(chainid, l1Token);
        } else {
            chainid = block.chainid;
            expectedAssetId = DataEncoding.encodeNTVAssetId(chainid, l2Token);
        }

        _assumeNotWeth(l2Token);

        if (
            ghost_tokenRegisteredWithL2NativeTokenVault[l2Token] ||
            l2NativeTokenVault.assetId(l2Token) != bytes32(0) ||
            l2Token.code.length == 0
        ) {
            return;
        }

        l2NativeTokenVault.tryRegisterTokenFromBurnData({_burnData: d, _expectedAssetId: expectedAssetId});

        ghost_tokenRegisteredWithL2NativeTokenVault[l2Token] = true;
    }

    function _boundTokenIndexAndGetTokenAddresses(uint256 _tokenIndex) internal returns (address, address) {
        uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

        (address l1Token, address l2Token) = _getL1TokenAndL2Token(tokens[tokenIndex]);

        return (l1Token, l2Token);
    }

    function _boundAmountAndAssumeBalance(uint256 _amount, address _token) internal returns (uint256) {
        if (_token.code.length == 0)
            assembly {
                return(0, 0)
            }

        uint256 balance = BridgedStandardERC20(_token).balanceOf(address(this));

        if (balance == 0)
            assembly {
                return(0, 0)
            }
        // without bounding the amount the handler usually tries to withdraw more than it has causing reverts
        // on the other hand we do want to test for "withdraw more than one has" cases
        // by bounding the amount for _some_ withdrawals we balance between having too many useless reverts
        // and testing too few cases
        return bound(_amount, 1, balance);
    }

    function _assumeRegisteredWithL2SharedBridge(address _token) internal {
        if (l2SharedBridge.l1TokenAddress(_token) == address(0))
            assembly {
                return(0, 0)
            }
    }

    function _assumeNotRegisteredWithNativeTokenVault(address _token) internal {
        if (l2AssetRouter.l1TokenAddress(_token) != address(0))
            assembly {
                return(0, 0)
            }
    }

    function _assumeNotRegistered(address _token) internal {
        if (l2SharedBridge.l1TokenAddress(_token) != address(0))
            assembly {
                return(0, 0)
            }
        _assumeNotRegisteredWithNativeTokenVault(_token);
    }

    function _assumeHasCodeAndNotWeth(address _token) internal {
        if (_token.code.length == 0)
            assembly {
                return(0, 0)
            }
        _assumeNotWeth(_token);
    }

    function _assumeNotWeth(address _token) internal {
        if (_token == l2NativeTokenVault.WETH_TOKEN())
            assembly {
                return(0, 0)
            }
    }
}
