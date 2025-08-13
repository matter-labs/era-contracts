// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0xddb74934
error InsufficientChainBalanceAssetTracker(uint256 chainId, bytes32 assetId, uint256 amount);
// 0x2c5211c6
error InvalidAmount();
// 0xfafca5a0
error InvalidAssetId();
// 0x61c1fbf6
error TokenBalanceNotMigratedToGateway(bytes32, uint256, uint256);
// 0x7ad8c2c9
error InvalidCanonicalTxHash(bytes32);
// 0x05208b6d
error InvalidChainMigrationNumber(uint256, uint256);
// 0x9530c5e1
error InvalidMigrationNumber(uint256, uint256);
// 0xddb5de5e
error InvalidSender();
// 0xf76b228a
error InvalidWithdrawalChainId();
// 0x8dfed13a
error NotMigratedChain();
// 0x43cca996
error OnlyWhitelistedSettlmentLayer(address, address);
