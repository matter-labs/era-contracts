// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

// 0x5825e8d8
error InsufficientInteropFeeBalance(uint256 chainId, uint256 balance, uint256 fee);
// 0x7ae7a034
error InteropFeeTransferFailed();
