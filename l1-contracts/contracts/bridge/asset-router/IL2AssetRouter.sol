// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IL2CrossChainSender} from "../interfaces/IL2CrossChainSender.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";

/// @title L2 Asset Router interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L2 side of asset routing. See {protocol-docs/bridging.md}.
interface IL2AssetRouter is IAssetRouterBase, IL2CrossChainSender {
    function L1_ASSET_ROUTER() external view returns (IL1AssetRouter);

    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

    /// @notice Sets the asset handler for an asset ID, as instructed by the L1 asset router.
    /// @param _sourceChainId The chain the instruction originates from (must be L1).
    /// @param _assetId The asset ID.
    /// @param _assetHandlerAddress The asset handler address to set.
    function setAssetHandlerAddress(uint256 _sourceChainId, bytes32 _assetId, address _assetHandlerAddress) external;
}
