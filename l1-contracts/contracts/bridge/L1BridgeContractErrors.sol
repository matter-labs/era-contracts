// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0xf4c3268c
error AssetHandlerNotAllowed(uint256 chainId, bytes32 assetId, address assetHandler);
// 0x4bf81b64
error AssetNotNativeToL1(bytes32 assetId, uint256 originChainId);
// 0xdbdc52e2
error ChainBalanceAlreadyInInteropPool(uint256 chainId, bytes32 assetId);
// 0xee77b256
error ChainBalanceBackfillAlreadySet(uint256 chainId, bytes32 assetId);
// 0x40b99a82
error ChainBalanceBackfillNotPending(uint256 chainId);
// 0x91181903
error ChainBalanceBackfillPending(uint256 chainId);
// 0x40fddfd0
error ChainBalanceExceeded(uint256 chainId, bytes32 assetId, uint256 totalWithdrawn, uint256 limit);
// 0x066f53b1
error EmptyToken();
// 0x459d6720
error InteropDepositChainNotOnL1(uint256 chainId);
// 0xabd51c42
error InteropWithdrawalNonZeroValue(uint256 value);
// 0x1c55230b
error NativeTokenVaultAlreadySet();
// 0x7ec6d3a1
error OnlyFailureStatusAllowed();
// 0x84204265
error TokenAlreadyInBridgedTokensList();
// 0xb4aeddbc
error WrongCounterpart();
// 0x61cdb17e
error WrongMsgLength(uint256 expected, uint256 length);
