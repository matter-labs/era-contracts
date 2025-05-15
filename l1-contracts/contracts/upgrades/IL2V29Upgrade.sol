// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IL2V29Upgrade {
    function upgrade(address _aliasedGovernance, bytes32 _bridgedEthAssetId) external;
}