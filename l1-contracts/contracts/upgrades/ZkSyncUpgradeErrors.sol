// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0x7a47c9a2
error InvalidChainId();
// 0xd7f8c13e
error PreviousUpgradeBatchNotCleared();
// 0x3c43ccce
error ProtocolMajorVersionNotZero();
// 0xd7f50a9d
error PatchCantSetUpgradeTxn();
// 0xd2c011d6
error L2UpgradeNonceNotEqualToNewProtocolVersion(uint256 nonce, uint256 protocolVersion);
// 0xcb5e4247
error L2BytecodeHashMismatch(bytes32 expected, bytes32 provided);
// 0x88d7b498
error ProtocolVersionTooSmall();
// 0x56d45b12
error ProtocolVersionTooBig();
// 0x5c598b60
error PreviousProtocolMajorVersionNotZero();
// 0x72ea85ad
error NewProtocolMajorVersionNotZero();
// 0xd328c12a
error ProtocolVersionMinorDeltaTooBig(uint256 limit, uint256 proposed);
// 0xe1a9736b
error ProtocolVersionDeltaTooLarge(uint256 _proposedDelta, uint256 _maxDelta);
// 0x6d172ab2
error ProtocolVersionShouldBeGreater(uint256 _oldProtocolVersion, uint256 _newProtocolVersion);
// 0x559cc34e
error PatchUpgradeCantSetDefaultAccount();
// 0x962fd7d0
error PatchUpgradeCantSetBootloader();
// 0x101ba748
error PreviousUpgradeNotFinalized(bytes32 txHash);
// 0xa0f47245
error PreviousUpgradeNotCleaned();
// 0x07218375
error UnexpectedNumberOfFactoryDeps();
// 0x76da24b9
error TooManyFactoryDeps();
// 0x5cb29523
error InvalidTxType(uint256 txType);
// 0x08753982
error TimeNotReached(uint256 expectedTimestamp, uint256 actualTimestamp);
// 0xd92e233d
error ZeroAddress();
