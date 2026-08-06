// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILegacyL1AssetTracker} from "contracts/bridge/asset-tracker/ILegacyL1AssetTracker.sol";

/// @dev Read-only stand-in for the v31 `L1AssetTracker`. The contract itself no longer exists in this
/// repository, so the storage the `bridgedOut` population reads on an upgraded ecosystem has to be mocked.
contract MockLegacyL1AssetTracker is ILegacyL1AssetTracker {
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;
    mapping(bytes32 assetId => bool) public isAssetRegistered;

    function setChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _balance) external {
        chainBalance[_chainId][_assetId] = _balance;
        isAssetRegistered[_assetId] = true;
    }
}
