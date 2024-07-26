// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAssetRouterBase} from "l1-contracts-imported/contracts/bridge/interfaces/IAssetRouterBase.sol";

/// @author Matter Labs
interface IL2AssetRouter is IAssetRouterBase {
    event WithdrawalInitiatedSharedBridge(
        uint256 chainId,
        address indexed l2Sender,
        bytes32 indexed assetId,
        bytes32 assetDataHash
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed _assetAddress);

    function withdraw(bytes32 _assetId, bytes calldata _data) external;

    function l1Bridge() external view returns (address);

    function l1SharedBridge() external view returns (address);

    function l1TokenAddress(address _l2Token) external view returns (address);
}
