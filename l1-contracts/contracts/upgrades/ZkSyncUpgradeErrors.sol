// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

error ProtocolVersionShouldBeGreater(uint256 _oldProtocolVersion, uint256 _newProtocolVersion);
error ProtocolVersionDeltaTooLarge(uint256 _proposedDelta, uint256 _maxDelta);
error PreviousUpgradeNotFinalized();
error PreviousUpgradeBatchNotCleared();
