// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";

import {L1_TOKEN_ADDRESS, TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS, AMOUNT_UPPER_BOUND} from "../common/Constants.sol";
import {UserActorHandler} from "./UserActorHandler.sol";

contract LegacyBridgeActorHandler is Test {
    UserActorHandler[] public users;
    address[] public l1Tokens;

    uint256 public ghost_totalDeposits;
    uint256 public ghost_totalWithdrawals;

    error UsersArrayIsEmpty();
    error L1TokensArrayIsEmpty();

    constructor(UserActorHandler[] memory _users, address[] memory _l1Tokens) {
        if (_users.length == 0) {
            revert UsersArrayIsEmpty();
        }
        users = _users;

        if (_l1Tokens.length == 0) {
            revert L1TokensArrayIsEmpty();
        }
        l1Tokens = _l1Tokens;
    }

    function finalizeDeposit(uint256 _amount, address _sender, uint256 _userIndex, uint256 _l1TokenIndex) public {
        uint256 amount = bound(_amount, 0, AMOUNT_UPPER_BOUND);
        uint256 userIndex = bound(_userIndex, 0, users.length - 1);
        uint256 l1TokenIndex = bound(_l1TokenIndex, 0, l1Tokens.length - 1);

        address l1Token = l1Tokens[l1TokenIndex];

        L2AssetRouter l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        uint256 l1ChainId = l2AssetRouter.L1_CHAIN_ID();
        bytes32 baseTokenAssetId = l2AssetRouter.BASE_TOKEN_ASSET_ID();

        if (DataEncoding.encodeNTVAssetId(l1ChainId, l1Token) == baseTokenAssetId) {
            return;
        }

        l2AssetRouter.finalizeDepositLegacyBridge({
            _l1Sender: _sender,
            _l2Receiver: address(users[userIndex]),
            _l1Token: l1Token,
            _amount: amount,
            _data: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });

        ghost_totalDeposits += amount;
    }

    function withdraw(uint256 _amount, uint256 _userIndex, address _l1Receiver, uint256 _l1TokenIndex) public {
        uint256 amount = bound(_amount, 0, AMOUNT_UPPER_BOUND);
        uint256 userIndex = bound(_userIndex, 0, users.length - 1);
        uint256 l1TokenIndex = bound(_l1TokenIndex, 0, l1Tokens.length - 1);

        L2AssetRouter l2AssetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        IL2SharedBridgeLegacy sharedBridge = IL2SharedBridgeLegacy(l2AssetRouter.L2_LEGACY_SHARED_BRIDGE());
        address l1Token = l1Tokens[l1TokenIndex];
        address l2Token = L2AssetRouter(L2_ASSET_ROUTER_ADDR).l2TokenAddress(l1Token);

        vm.assume(sharedBridge.l1TokenAddress(l2Token) != address(0));
        vm.assume(l2NativeTokenVault.assetId(l2Token) != bytes32(0));

        L2AssetRouter(L2_ASSET_ROUTER_ADDR).withdrawLegacyBridge({
            _l1Receiver: _l1Receiver,
            _l2Token: l2Token,
            _amount: amount,
            _sender: address(users[userIndex])
        });

        ghost_totalWithdrawals += amount;
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
