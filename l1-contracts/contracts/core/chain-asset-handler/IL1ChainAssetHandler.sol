// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1ChainAssetHandler {
    function isMigrationInProgress(uint256 _chainId) external view returns (bool);
}
