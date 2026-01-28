// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

struct Transaction {
    string[] additionalContracts;
    bytes32[] arguments;
    address contractAddress;
    string functionKey;
    bytes32 hash;
    bool isFixedGasLimit;
    string transactionType;
}
