// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title L1 Base Token Asset Handler contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Used for any asset handler and called by the L1AssetRouter
interface IL1BaseTokenAssetHandler {
    /// @notice Used to get the token address of an assetId
    function tokenAddress(bytes32 _assetId) external view returns (address);
}
