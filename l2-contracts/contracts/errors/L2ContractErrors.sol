// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

// 0x5e85ae73
error AmountMustBeGreaterThanZero();
// 0x7138356f
error EmptyAddress();
// 0x1bdfd505
error FailedToTransferTokens(address tokenContract, address to, uint256 amount);
// 0x2a1b2dd8
error InsufficientAllowance(uint256 providedAllowance, uint256 requiredAmount);
// 0xb4fa3fb3
error InvalidInput();
// 0x8e4a23d6
error Unauthorized(address);
// 0x6e128399
error Unimplemented();
// 0xff15b069
error UnsupportedPaymasterFlow();
// 0x750b219c
error WithdrawFailed();
error MalformedBytecode(BytecodeError);

enum BytecodeError {
    Version,
    NumberOfWords,
    Length,
    WordsMustBeOdd,
    DictionaryLength
}
// 0xd92e233d
error ZeroAddress();
