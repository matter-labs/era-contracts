// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

bytes1 constant BALANCE_CHANGE_VERSION = bytes1(uint8(1));
bytes1 constant TOKEN_BALANCE_MIGRATION_DATA_VERSION = bytes1(uint8(1));

interface IAssetTrackerBase {
    function tokenMigratedThisChain(bytes32 _assetId) external view returns (bool);

    function tokenMigrated(uint256 _chainId, bytes32 _assetId) external view returns (bool);

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) external;

    function registerLegacyTokenOnChain(bytes32 _assetId) external;

    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    function totalSupplyAcrossAllChains(bytes32 _assetId) external view returns (uint256);
}
