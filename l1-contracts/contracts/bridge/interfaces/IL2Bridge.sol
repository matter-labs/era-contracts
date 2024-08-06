// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2Bridge {
    function withdraw(bytes32 _assetId, bytes memory _assetData) external;

    function finalizeDeposit(bytes32 _assetId, bytes calldata _transferData) external;

    function l1Bridge() external view returns (address);

    function setAssetHandlerAddress(bytes32 _assetId, address _assetAddress) external;
}
