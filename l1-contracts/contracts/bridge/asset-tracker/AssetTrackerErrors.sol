// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0xddb74934
error InsufficientChainBalanceAssetTracker(uint256 chainId, bytes32 assetId, uint256 amount);
// 0x2c5211c6
error InvalidAmount();
// 0xfafca5a0
error InvalidAssetId();
// 0x019cd955
error InvalidBaseTokenAssetId();
// 0xd24c490f
error InvalidBuiltInContractMessage(uint256 logCount, uint256 msgCount, bytes32 key);
// 0x7ad8c2c9
error InvalidCanonicalTxHash(bytes32);
// 0x05208b6d
error InvalidChainMigrationNumber(uint256, uint256);
// 0x24ef4f8a
error InvalidEmptyMessageRoot(bytes32, bytes32);
// 0x9530c5e1
error InvalidMigrationNumber(uint256, uint256);
// 0xc5ac5599
error InvalidOriginChainId();
// 0xddb5de5e
error InvalidSender();
// 0xf76b228a
error InvalidWithdrawalChainId();
// 0x2ef97090
error L1ToL2DepositsNotFinalized();
// 0x8dfed13a
error NotMigratedChain();
// 0x0fd3385e
error OnlyWhitelistedSettlementLayer(address, address);
// 0x90ed63bb
error TokenBalanceNotMigratedToGateway(bytes32, uint256, uint256);
