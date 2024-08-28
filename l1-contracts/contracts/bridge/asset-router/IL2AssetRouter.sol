// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAssetRouterBase} from "./IAssetRouterBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2AssetRouter is IAssetRouterBase {
    event FinalizeDepositSharedBridge(uint256 chainId, bytes32 indexed assetId, bytes assetData);

    event WithdrawalInitiatedSharedBridge(
        uint256 chainId,
        address indexed l2Sender,
        bytes32 indexed assetId,
        bytes assetData
    );

    function finalizeDeposit(bytes32 _assetId, bytes calldata _transferData) external;

    function withdraw(bytes32 _assetId, bytes calldata _transferData) external;

    // function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    function l1AssetRouter() external view returns (address);

    function withdrawLegacyBridge(address _l1Receiver, address _l2Token, uint256 _amount, address _sender) external;

    /// @dev Used to set the assedAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(uint256 _originChainId, bytes32 _assetId, address _assetAddress) external;
}
