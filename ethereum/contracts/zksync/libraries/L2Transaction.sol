// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice Structure that contains an L2 transaction without calldata
/// @dev used to prevent deep stack error
struct L2Transaction {
    address l2Contract; //L2 transaction msg.to
    uint256 l2Value; //L2 transaction msg.value
    uint256 l2GasLimit; //Maximum amount of L2 gas that transaction can consume during execution on L2
    uint256 l2GasPerPubdataByteLimit; //The maximum amount L2 gas that the operator may charge the user for single byte of pubdata
}