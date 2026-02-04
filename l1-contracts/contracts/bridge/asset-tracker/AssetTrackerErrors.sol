// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0xda72d995
error AssetIdNotRegistered(bytes32 _assetId);
// 0x07859b3b
error InsufficientChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount);
// 0x95bddd6c
error InvalidAssetMigrationNumber();
// 0xd24c490f
error InvalidBuiltInContractMessage(uint256 logCount, uint256 msgCount, bytes32 key);
// 0x7ad8c2c9
error InvalidCanonicalTxHash(bytes32);
// 0x05208b6d
error InvalidChainMigrationNumber(uint256, uint256);
// 0x24ef4f8a
error InvalidEmptyMessageRoot(bytes32 expectedMessageRoot, bytes32 providedMessageRoot);
// 0x768dc598
error InvalidFeeRecipient();
// 0x532a43fc
error InvalidFunctionSignature(bytes4 functionSignature);
// 0xfbf8ed35
error InvalidInteropBalanceChange(bytes32 bundleHash);
// 0x203d8be5
error InvalidInteropChainId(uint256 fromChainId, uint256 toChainId);
// 0xeaa867a8
error InvalidL1AssetRouter(address l1AssetRouter);
// 0xe1fe041e
error InvalidL2ShardId();
// 0x9530c5e1
error InvalidMigrationNumber(uint256, uint256);
// 0xddb5de5e
error InvalidSender();
// 0xaca75b50
error InvalidServiceLog();
// 0xd0f0bff7
error InvalidSettlementLayer();
// 0xa9146eeb
error InvalidVersion();
// 0xf76b228a
error InvalidWithdrawalChainId();
// 0xa16d8a80
error L1TotalSupplyAlreadyMigrated();
// 0xda4352c4
error MaxChainBalanceAlreadyAssigned(bytes32 assetId);
// 0x7e472272
error MissingBaseTokenAssetId();
// 0x8dfed13a
error NotMigratedChain();
// 0x4a22c4b8
error OnlyGatewaySettlementLayer();
// 0x0fd3385e
error OnlyWhitelistedSettlementLayer(address, address);
// 0x174996d5
error RegisterNewTokenNotAllowed();
// 0xaad86dcd
error SettlementFeePayerNotAgreed(address payer, uint256 chainId);
// 0x90ed63bb
error TokenBalanceNotMigratedToGateway(bytes32, uint256, uint256);
// 0x03a5ba47
error TransientBalanceChangeAlreadySet(uint256 storedAssetId, uint256 storedAmount);
