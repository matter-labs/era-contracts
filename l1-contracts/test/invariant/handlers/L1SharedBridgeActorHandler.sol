// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";

import {L1_TOKEN_ADDRESS, TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS, AMOUNT_UPPER_BOUND} from "../common/Constants.sol";
import {Token} from "../common/Types.sol";
import {UserActorHandler} from "./UserActorHandler.sol";
import {ActorHandler} from "./ActorHandler.sol";

contract L1SharedBridgeActorHandler is ActorHandler {
    address[] public receivers;

    uint256 public ghost_totalDeposits;
    uint256 public ghost_totalWithdrawals;

    error UsersArrayIsEmpty();
    error L1TokensArrayIsEmpty();

    constructor(address[] memory _receivers, Token[] memory _tokens) ActorHandler(_tokens) {
        if (_receivers.length == 0) {
            revert UsersArrayIsEmpty();
        }
        receivers = _receivers;
    }

    function finalizeDeposit(uint256 _amount, address _sender, uint256 _userIndex, uint256 _tokenIndex) public {
        uint256 amount = bound(_amount, 0, AMOUNT_UPPER_BOUND);
        uint256 userIndex = bound(_userIndex, 0, receivers.length - 1);
        uint256 tokenIndex = bound(_tokenIndex, 0, tokens.length - 1);

        Token memory token = tokens[tokenIndex];

        vm.assume(token.bridged);

        (address l1Token, address l2Token) = _getL1TokenAndL2Token(tokens[tokenIndex]);

        L2AssetRouter l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        uint256 l1ChainId = l2AssetRouter.L1_CHAIN_ID();
        bytes32 baseTokenAssetId = l2AssetRouter.BASE_TOKEN_ASSET_ID();

        vm.assume(DataEncoding.encodeNTVAssetId(l1ChainId, l1Token) == baseTokenAssetId);

        l2SharedBridge.finalizeDeposit({
            _l1Sender: _sender,
            _l2Receiver: receivers[userIndex],
            _l1Token: l1Token,
            _amount: amount,
            _data: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });

        ghost_totalDeposits += amount;
    }

    // borrowed from https://github.com/matter-labs/era-contracts/blob/16dedf6d77695ce00f81fce35a3066381b97fca1/l1-contracts/test/foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol#L203-L217
    /// @notice Encodes the token data.
    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    /// @param decimals The decimals of the token.
    function encodeTokenData(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal pure returns (bytes memory) {
        bytes memory encodedName = abi.encode(name);
        bytes memory encodedSymbol = abi.encode(symbol);
        bytes memory encodedDecimals = abi.encode(decimals);

        return abi.encode(encodedName, encodedSymbol, encodedDecimals);
    }
}
