// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IL2CrossChainSender} from "../interfaces/IL2CrossChainSender.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2AssetRouter is IAssetRouterBase, IL2CrossChainSender {
    event WithdrawalInitiatedAssetRouter(
        uint256 chainId,
        address indexed l2Sender,
        bytes32 indexed assetId,
        bytes assetData
    );

    function withdraw(bytes32 _assetId, bytes calldata _transferData) external returns (bytes32);

    function L1_ASSET_ROUTER() external view returns (IL1AssetRouter);

    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @dev Used to set the assetHandlerAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(uint256 _originChainId, bytes32 _assetId, address _assetHandlerAddress) external;
}
