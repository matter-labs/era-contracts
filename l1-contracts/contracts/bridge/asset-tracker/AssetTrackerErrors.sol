// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x7a734a36
error AssetAlreadyRegistered(bytes32 assetId);
// 0xda72d995
error AssetIdNotRegistered(bytes32 _assetId);
// 0x8361ff70
error BaseTokenNativeToThisChain();
// 0xca9bc458
error BaseTokenTotalSupplyBackfillNotNeeded();
// 0xd054a77e
error ChainBalanceMustBeZeroBeforeMigration(uint256 _chainId, bytes32 _assetId, uint256 _chainBalance);
// 0x07859b3b
error InsufficientChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount);
// 0xeaa867a8
error InvalidL1AssetRouter(address l1AssetRouter);
// 0x7e472272
error MissingBaseTokenAssetId();
// 0x34838ed2
error TotalPreV31SupplyNotSaved(bytes32 _assetId);
// 0x0a767367
error TotalPreV31SupplyShouldBeZero(bytes32 _assetId, uint256 _totalSupply);
