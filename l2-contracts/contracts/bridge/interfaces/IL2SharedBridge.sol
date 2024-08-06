// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2SharedBridge {
    event FinalizeDepositSharedBridge(uint256 chainId, bytes32 indexed assetId, bytes32 assetDataHash);

    event WithdrawalInitiatedSharedBridge(
        uint256 chainId,
        address indexed l2Sender,
        bytes32 indexed assetId,
        bytes32 assetDataHash
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed _assetAddress);

    function finalizeDeposit(bytes32 _assetId, bytes calldata _data) external;

    function withdraw(bytes32 _assetId, bytes calldata _data) external;

    function l1Bridge() external view returns (address);

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    function l1SharedBridge() external view returns (address);

    function l1TokenAddress(address _l2Token) external view returns (address);
}
