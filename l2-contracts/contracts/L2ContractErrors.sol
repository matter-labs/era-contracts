// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 0xcbd9d2e0
error InvalidCaller(address);
// 0xb4fa3fb3
error InvalidInput();
// 0x2a1b2dd8
error InsufficientAllowance(uint256 providedAllowance, uint256 requiredAmount);
// 0x1bdfd505
error FailedToTransferTokens(address tokenContract, address to, uint256 amount);
// 0xff15b069
error UnsupportedPaymasterFlow();
// 0x7138356f
error EmptyAddress();
// 0x1c25715b
error EmptyBytes32();
// 0x1f73225f
error AddressMismatch(address expected, address supplied);
// 0x5e85ae73
error AmountMustBeGreaterThanZero();
// 0xb4f54111
error DeployFailed();
// 0x82b42900
error Unauthorized();
// 0x0ac76f01
error NonSequentialVersion();
// 0x6e128399
error Unimplemented();
// 0xa4dde386
error UnimplementedMessage(string);
// 0x750b219c
error WithdrawFailed();

string constant BRIDGE_MINT_NOT_IMPLEMENTED = "bridgeMint is not implemented! Use deposit/depositTo methods instead.";
