// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

// 0x1f73225f
error AddressMismatch(address expected, address supplied);
// 0x5e85ae73
error AmountMustBeGreaterThanZero();
// 0xb4f54111
error DeployFailed();
// 0x7138356f
error EmptyAddress();
// 0x1c25715b
error EmptyBytes32();
// 0x1bdfd505
error FailedToTransferTokens(address tokenContract, address to, uint256 amount);
// 0x2a1b2dd8
error InsufficientAllowance(uint256 providedAllowance, uint256 requiredAmount);
// 0xcbd9d2e0
error InvalidCaller(address);
// 0xb4fa3fb3
error InvalidInput();
// 0x0ac76f01
error NonSequentialVersion();
// 0x8e4a23d6
error Unauthorized(address);
// 0x6e128399
error Unimplemented();
// 0xa4dde386
error UnimplementedMessage(string message);
// 0xff15b069
error UnsupportedPaymasterFlow();
// 0x750b219c
error WithdrawFailed();
// 0xd92e233d
error ZeroAddress();

string constant BRIDGE_MINT_NOT_IMPLEMENTED = "bridgeMint is not implemented! Use deposit/depositTo methods instead.";
