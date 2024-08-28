// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2Bridge {
    function withdraw(bytes32 _assetId, bytes memory _assetData) external;

    function finalizeDeposit(bytes32 _assetId, bytes calldata _transferData) external;

    function l1Bridge() external view returns (address);

    function setAssetHandlerAddress(bytes32 _assetId, address _assetAddress) external;
}
