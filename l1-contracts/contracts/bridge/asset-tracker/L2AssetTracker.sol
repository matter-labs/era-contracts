// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";

contract L2AssetTracker is IL2AssetTracker {
    function handleChainBalanceIncrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) external {
        // we don't do anything when receiving funds on L2
    }

    function handleChainBalanceDecrease(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isNative
    ) external {
        // TODO: implement
    }
}
