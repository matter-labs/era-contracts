// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2Bridgehub {
    function registerChainForInterop(uint256 _chainId, bytes32 _baseTokenAssetId) external;
}