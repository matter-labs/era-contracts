// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @dev Minimum byte length of an ERC-7930 v1 address:
/// version (2) + chainType (2) + chainReferenceLength (1) + addressLength (1).
uint256 constant ERC7930_V1_MIN_LENGTH = 0x06;

/// @dev Storage slot of `L1_CHAIN_ID` in mainnet v31's interop handler, which inherited `PausableUpgradeable`.
/// It lies outside the current `L2InteropHandler` layout; see
/// {protocol-docs/interop/architecture.md#l2interophandler-storage-across-the-v31--v33-upgrade}.
uint256 constant V31_INTEROP_HANDLER_L1_CHAIN_ID_SLOT = 101;
