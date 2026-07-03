// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x7a734a36
error AssetAlreadyRegistered(bytes32 assetId);
// 0xda72d995
error AssetIdNotRegistered(bytes32 _assetId);
// 0xca9bc458
error BaseTokenTotalSupplyBackfillNotNeeded();
// 0xd054a77e
error ChainBalanceMustBeZeroBeforeMigration(uint256 _chainId, bytes32 _assetId, uint256 _chainBalance);
// 0x07859b3b
error InsufficientChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount);
// 0xb13a28eb
error InsufficientPendingInteropBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount);
// 0xd24c490f
error InvalidBuiltInContractMessage(uint256 logCount, uint256 msgCount, bytes32 key);
// 0x7ad8c2c9
error InvalidCanonicalTxHash(bytes32);
// 0x768dc598
error InvalidFeeRecipient();
// 0x532a43fc
error InvalidFunctionSignature(bytes4 functionSignature);
// 0xe1fe041e
error InvalidL2ShardId();
// 0xaca75b50
error InvalidServiceLog();
// 0x7e472272
error MissingBaseTokenAssetId();
// 0x174996d5
error RegisterNewTokenNotAllowed();
// 0xaad86dcd
error SettlementFeePayerNotAgreed(address payer, uint256 chainId);
// 0x34838ed2
error TotalPreV31SupplyNotSaved(bytes32 _assetId);
// 0x0a767367
error TotalPreV31SupplyShouldBeZero(bytes32 _assetId, uint256 _totalSupply);
