// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0x6d963f88
error EthTransferFailed();

// 0x1c55230b
error NativeTokenVaultAlreadySet();

// 0x61cdb17e
error WrongMsgLength(uint256 expected, uint256 length);

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

// 0xb4aeddbc
error WrongCounterpart();
