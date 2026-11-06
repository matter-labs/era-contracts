// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IAssetRouterBase} from "./IAssetRouterBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2AssetRouter is IAssetRouterBase {
    event WithdrawalInitiatedAssetRouter(
        uint256 chainId,
        address indexed l2Sender,
        bytes32 indexed assetId,
        bytes assetData
    );

    function withdraw(bytes32 _assetId, bytes calldata _transferData) external returns (bytes32);

    function L1_ASSET_ROUTER() external view returns (address);

    function withdrawLegacyBridge(address _l1Receiver, address _l2Token, uint256 _amount, address _sender) external;

    function finalizeDepositLegacyBridge(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external;

    /// @dev Used to set the assetHandlerAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(uint256 _originChainId, bytes32 _assetId, address _assetHandlerAddress) external;

    /// @notice Function that allows native token vault to register itself as the asset handler for
    /// a legacy asset.
    /// @param _assetId The assetId of the legacy token.
    function setLegacyTokenAssetHandler(bytes32 _assetId) external;
}
