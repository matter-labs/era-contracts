// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0xda72d995
error AssetIdNotRegistered(bytes32 _assetId);
// 0xa65b4be1
error ChainBalanceNotZero();
// 0x07859b3b
error InsufficientChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount);
// 0xddb74934
error InsufficientChainBalanceAssetTracker(uint256 chainId, bytes32 assetId, uint256 amount);
// 0xceffb473
error InsufficientTotalSupply(bytes32 _assetId, uint256 _amount);
// 0x2c5211c6
error InvalidAmount();
// 0x2e19b556
error InvalidAssetId(bytes32);
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
// 0x532a43fc
error InvalidFunctionSignature(bytes4 functionSignature);
// 0x203d8be5
error InvalidInteropChainId(uint256 fromChainId, uint256 toChainId);
// 0xe1fe041e
error InvalidL2ShardId();
// 0x9530c5e1
error InvalidMigrationNumber(uint256, uint256);
// 0xc5ac5599
error InvalidOriginChainId();
// 0xddb5de5e
error InvalidSender();
// 0xaca75b50
error InvalidServiceLog();
// 0x142bd5be
error InvalidV30UpgradeChainBatchNumber(uint256 _chainId);
// 0xf76b228a
error InvalidWithdrawalChainId();
// 0x2ef97090
error L1ToL2DepositsNotFinalized();
// 0x7e472272
error MissingBaseTokenAssetId();
// 0x1d16d015
error NotEnoughChainBalance(uint256 _sourceChainId, bytes32 _assetId, uint256 _amount);
// 0x8dfed13a
error NotMigratedChain();
// 0x4a22c4b8
error OnlyGatewaySettlementLayer();
// 0x0fd3385e
error OnlyWhitelistedSettlementLayer(address, address);
// 0xd4f29820
error OnlyWithdrawalsAllowedForPreV30Chains();
// 0x90ed63bb
error TokenBalanceNotMigratedToGateway(bytes32, uint256, uint256);
