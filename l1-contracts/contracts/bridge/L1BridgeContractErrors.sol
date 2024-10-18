// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0xe4efb466
error NotNTV();

// 0x6d963f88
error EthTransferFailed();

// 0x1c55230b
error NativeTokenVaultAlreadySet();

// 0xe3c3f6ac
error LegacyEthWithdrawalNotSupported();

// 0x7bbae404
error LegacyTokenWithdrawal();

// 0x61cdb17e
error WrongMsgLength(uint256 expected, uint256 length);

// 0xf01fa4d4
error NotNTVorADT(address msgSender, address deploymentTracker);

// 0x802e4e50
error AssetHandlerNotSet();

// 0x2bd50ff1
error NewEncodingFormatNotYetSupportedForNTV(address deploymentTracker, address nativeTokenVault);

// 0xfd56d779
error AssetHandlerDoesNotExistForAssetId();

// 0x8175b04c
error EthOnlyAcceptedFromSharedBridge(address sharedBridge, address msgSender);

// 0xe4742c42
error ZeroAmountToTransfer();

// 0xfeda3bf8
error WrongAmountTransferred(uint256 balance, uint256 nullifierChainBalance);

// 0x066f53b1
error EmptyToken();

// 0x0fef9068
error ClaimFailedDepositFailed();

// 0x636c90db
error WrongL2Sender(address providedL2Sender);
