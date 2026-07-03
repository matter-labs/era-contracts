// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

uint256 constant MAX_TOKEN_BALANCE = type(uint256).max;

struct SavedTotalSupply {
    bool isSaved;
    uint256 amount;
}

interface IAssetTrackerBase {
    function registerNewTokenIfNeeded(bytes32 _assetId, uint256 _originChainId) external;

    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    function isAssetRegistered(bytes32 _assetId) external view returns (bool);
}
