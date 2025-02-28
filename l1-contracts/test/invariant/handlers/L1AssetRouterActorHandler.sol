// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";

import {L1_TOKEN_ADDRESS, TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS, AMOUNT_UPPER_BOUND} from "../common/Constants.sol";
import {UserActorHandler} from "./UserActorHandler.sol";

// no cheatcodes here because they won't work with `--zksync`
// forge 0.0.2 (27360d4 2024-12-02T00:28:35.872943000Z)
contract L1AssetRouterActorHandler is Test {
    UserActorHandler[] public receivers;
    address[] public l1Tokens;

    uint256 public ghost_totalDeposits;

    error ReceiversArrayIsEmpty();
    error ArrayIsEmpty();

    constructor(UserActorHandler[] memory _receivers, address[] memory _l1Tokens) {
        if (_receivers.length == 0) {
            revert ReceiversArrayIsEmpty();
        }
        receivers = _receivers;

        if (_l1Tokens.length == 0) {
            revert ArrayIsEmpty();
        }
        l1Tokens = _l1Tokens;
    }

    function finalizeDeposit(uint256 _amount, address _sender, uint256 _receiverIndex, uint256 _l1TokenIndex) public {
        _amount = bound(_amount, 0, AMOUNT_UPPER_BOUND);
        uint256 receiverIndex = bound(_receiverIndex, 0, receivers.length - 1);
        uint256 l1TokenIndex = bound(_l1TokenIndex, 0, l1Tokens.length - 1);

        address l1Token = l1Tokens[l1TokenIndex];

        L2AssetRouter l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        uint256 l1ChainId = l2AssetRouter.L1_CHAIN_ID();
        bytes32 baseTokenAssetId = l2AssetRouter.BASE_TOKEN_ASSET_ID();

        if (DataEncoding.encodeNTVAssetId(l1ChainId, l1Token) == baseTokenAssetId) {
            return;
        }

        l2AssetRouter.finalizeDeposit({
            _l1Sender: _sender,
            _l2Receiver: address(receivers[receiverIndex]),
            _l1Token: l1Token,
            _amount: _amount,
            _data: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });

        ghost_totalDeposits += _amount;
    }

    function finalizeDepositV2(uint256 _amount, address _sender, uint256 _receiverIndex, uint256 _l1TokenIndex) public {
        uint256 receiverIndex = bound(_receiverIndex, 0, receivers.length - 1);
        uint256 l1TokenIndex = bound(_l1TokenIndex, 0, l1Tokens.length - 1);
        uint256 amount = bound(_amount, 0, AMOUNT_UPPER_BOUND);

        L2AssetRouter l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        uint256 l1ChainId = l2AssetRouter.L1_CHAIN_ID();
        address l1Token = l1Tokens[l1TokenIndex];
        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, l1Token);
        bytes32 baseTokenAssetId = l2AssetRouter.BASE_TOKEN_ASSET_ID();

        console.log("l1Token", l1Token);

        bytes memory data = DataEncoding.encodeBridgeMintData({
            _originalCaller: _sender,
            _remoteReceiver: address(receivers[receiverIndex]),
            _originToken: l1Token,
            _amount: amount,
            _erc20Metadata: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });

        if (assetId == baseTokenAssetId) {
            return;
        }

        // the 1st parameter is unused by `L2AssetRouter`
        // https://github.com/matter-labs/era-contracts/blob/ac11ba99e3f2c3365a162f587b17e35b92dc4f24/l1-contracts/contracts/bridge/asset-router/L2AssetRouter.sol#L132
        l2AssetRouter.finalizeDeposit(0, assetId, data);

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
