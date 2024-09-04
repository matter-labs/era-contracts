// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2AssetRouter {
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
}
