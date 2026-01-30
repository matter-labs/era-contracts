// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2NativeTokenVault contract
 */
interface IL2NativeTokenVault {
    function tokenAddress(bytes32 _assetId) external view returns (address);
}
