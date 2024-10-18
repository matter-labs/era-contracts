// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

error NotNTV();

error EthTransferFailed();

error NativeTokenVaultAlreadySet();

error LegacyEthWithdrawalNotSupported();

error LegacyTokenWithdrawal();

error WrongMsgLength(uint256 expected, uint256 length);

error NotNTVorADT(address msgSender, address deploymentTracker);

error AssetHandlerNotSet();

error NewEncodingFormatNotYetSupportedForNTV(address deploymentTracker, address nativeTokenVault);

error AssetHandlerDoesNotExistForAssetId();

error EthOnlyAcceptedFromSharedBridge(address sharedBridge, address msgSender);

error ZeroAmountToTransfer();

error WrongAmountTransferred(uint256 balance, uint256 nullifierChainBalance);

error EmptyToken();

error ClaimFailedDepositFailed();

error WrongL2Sender(address providedL2Sender);
