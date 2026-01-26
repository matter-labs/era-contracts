// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2V31Upgrade {
    function upgrade(uint256 _baseTokenOriginChainId, address _baseTokenOriginAddress, bool _isZkSyncOS) external;
}
