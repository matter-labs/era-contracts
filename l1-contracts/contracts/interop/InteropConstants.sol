// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @dev Minimum byte length of an ERC-7930 v1 address:
/// version (2) + chainType (2) + chainReferenceLength (1) + addressLength (1).
uint256 constant ERC7930_V1_MIN_LENGTH = 0x06;
