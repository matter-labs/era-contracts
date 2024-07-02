// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// 0x88d7b498
error ProtocolVersionTooSmall();
// 0xe1a9736b
error ProtocolVersionDeltaTooLarge(uint256 _proposedDelta, uint256 _maxDelta);
// 0xa0bdf77d
error PreviousUpgradeNotFinalized();
// 0xd7f8c13e
error PreviousUpgradeBatchNotCleared();
// 0x7a47c9a2
error InvalidChainId();
// 0xd92e233d
error ZeroAddress();
// 0x3c43ccce
error ProtocolMajorVersionNotZero();
