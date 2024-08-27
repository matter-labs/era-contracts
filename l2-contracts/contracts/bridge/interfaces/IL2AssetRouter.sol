// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAssetRouterBase} from "../../l1-contracts-imported/contracts/bridge/interfaces/IAssetRouterBase.sol";

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

    event AssetHandlerRegisteredInitial(
        bytes32 indexed assetId,
        address indexed assetAddress,
        bytes32 indexed additionalData,
        address sender
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed _assetAddress);

    function finalizeDeposit(bytes32 _assetId, bytes calldata _transferData) external;

    function withdraw(bytes32 _assetId, bytes calldata _transferData) external;

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    function l1AssetRouter() external view returns (address);

    function withdrawLegacyBridge(address _l1Receiver, address _l2Token, uint256 _amount, address _sender) external;
}
