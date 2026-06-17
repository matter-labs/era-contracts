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

    /// @notice Reverses an atomic-interop leg's source burn for an expired flow, returning the funds to
    /// the depositor via the native token vault. Callable only by the canonical atomic-flow manager,
    /// which gates it on a proven IMT non-inclusion (timeout). The original burn flowed through the
    /// normal `initiateIndirectCall` path during `InteropCenter.sendBundle`.
    /// @param _destChainId The destination chain id used at burn time (for chain-balance accounting).
    /// @param _assetId The asset being recovered.
    /// @param _recoverData Bridge-mint-formatted data whose receiver is the original depositor.
    function recoverAtomicBurn(uint256 _destChainId, bytes32 _assetId, bytes calldata _recoverData) external;

    function L1_ASSET_ROUTER() external view returns (IL1AssetRouter);

    function BASE_TOKEN_ASSET_ID() external view returns (bytes32);

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
