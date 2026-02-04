// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0xb334f781
error GenesisUpgradeExpectedOnSettlementLayer();
// 0x5cb29523
error InvalidTxType(uint256 txType);
// 0xd2c011d6
error L2UpgradeNonceNotEqualToNewProtocolVersion(uint256 nonce, uint256 protocolVersion);
// 0x72ea85ad
error NewProtocolMajorVersionNotZero();
// 0xd7f50a9d
error PatchCantSetUpgradeTxn();
// 0x962fd7d0
error PatchUpgradeCantSetBootloader();
// 0x559cc34e
error PatchUpgradeCantSetDefaultAccount();
// 0xc231eccd
error PatchUpgradeCantSetEvmEmulator();
// 0x5c598b60
error PreviousProtocolMajorVersionNotZero();
// 0xd7f8c13e
error PreviousUpgradeBatchNotCleared();
// 0xa0f47245
error PreviousUpgradeNotCleaned();
// 0x101ba748
error PreviousUpgradeNotFinalized(bytes32 txHash);
// 0x3c43ccce
error ProtocolMajorVersionNotZero();
// 0xe1a9736b
error ProtocolVersionDeltaTooLarge(uint256 _proposedDelta, uint256 _maxDelta);
// 0xd328c12a
error ProtocolVersionMinorDeltaTooBig(uint256 limit, uint256 proposed);
// 0x2ea43a45
error ProtocolVersionTooSmall(uint256 _previousProtocolVersion, uint256 _newProtocolVersion);
// 0x364b6f8b
error SettlementLayerUpgradeMustPrecedeChainUpgrade();
