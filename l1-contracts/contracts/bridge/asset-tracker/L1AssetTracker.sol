// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IL1AssetTracker} from "./IL1AssetTracker.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "../ntv/IL1NativeTokenVault.sol";

import {OriginChainIdNotFound, Unauthorized, ZeroAddress, NoFundsTransferred, InsufficientChainBalance, WithdrawFailed} from "../../common/L1ContractErrors.sol";

contract L1AssetTracker is IL1AssetTracker {

    IL1AssetRouter public immutable L1_ASSET_ROUTER;

    IL1NativeTokenVault public immutable L1_NATIVE_TOKEN_VAULT;

    constructor(address _l1AssetRouter, address _l1NativeTokenVault) {
        L1_ASSET_ROUTER = IL1AssetRouter(_l1AssetRouter);
        L1_NATIVE_TOKEN_VAULT = IL1NativeTokenVault(_l1NativeTokenVault);
    }

    function initialize() external {
        // TODO: implement
    }

    function migrateChainBalance(uint256 _chainId, bytes32 _assetId) external {
        // TODO: implement
    }

    function handleChainBalanceIncrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) external {
        chainBalance[_chainId][_assetId] += _amount;
    }

    function handleChainBalanceDecrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) external {
        // Check that the chain has sufficient balance
        if (chainBalance[_chainId][_assetId] < _amount) {
            revert InsufficientChainBalance();
        }
        chainBalance[_chainId][_assetId] -= _amount;
    }
}
