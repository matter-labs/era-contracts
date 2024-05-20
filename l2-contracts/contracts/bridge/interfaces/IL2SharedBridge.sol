// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @author Matter Labs
interface IL2SharedBridge {
    event FinalizeDepositSharedBridge(uint256 chainId, bytes32 indexed assetInfo, bytes32 assetDataHash);

    event WithdrawalInitiatedSharedBridge(
        uint256 chainId,
        address indexed l2Sender,
        bytes32 indexed assetInfo,
        bytes32 assetDataHash
    );

    function finalizeDeposit(bytes32 _assetInfo, bytes calldata _data) external;

    function withdraw(bytes32 _assetInfo, bytes calldata _data) external;

    function l1Bridge() external view returns (address);

    function assetAddress(bytes32 _assetInfo) external view returns (address);

    function l1SharedBridge() external view returns (address);

    function l1TokenAddress(address _l2Token) external view returns (address);
}
