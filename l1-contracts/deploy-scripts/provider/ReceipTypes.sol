// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct L2ToL1LogProof {
    uint64 id;
    bytes32[] proof;
}

struct AltL2ToL1Log {
    bytes32 blockHash;
    uint256 blockNumber;
    // uint256 isService;
    bytes32 key;
    uint256 l1BatchNumber;
    uint256 logIndex;
    address sender;
    uint256 shardId;
    bytes32 transactionHash;
    uint256 transactionIndex;
    uint256 transactionLogIndex;
    uint256 txIndexInL1Batch;
    bytes32 value;
}

struct L2ToL1Log {
    uint64 blockNumber;
    bytes32 blockHash;
    // bool isService;
    bytes32 key;
    uint64 logIndex;
    uint64 l1BatchNumber;
    address sender;
    uint64 shardId;
    bytes32 transactionHash;
    uint64 transactionIndex;
    uint64 transactionLogIndex;
    uint64 txIndexInL1Batch;
    bytes32 value;
}

struct AltLog {
    uint256 addr;
    bytes32 blockHash;
    uint256 blockNumber;
    uint256 blockTimestamp;
    // string data;
    uint256 l1BatchNumber;
    uint256 logIndex;
    // string logType;
    // string removed;
    // bytes32[] topics;
    bytes32 transactionHash;
    uint256 transactionIndex;
    uint256 transactionLogIndex;
}

struct Log {
    address addr;
    bytes32 blockHash;
    uint64 blockNumber;
    uint64 blockTimestamp;
    bytes data;
    uint64 logIndex;
    // string logType;
    uint64 l1BatchNumber;
    // bool removed;
    bytes32[] topics;
    uint64 transactionIndex;
    bytes32 transactionHash;
    uint64 transactionLogIndex;
}

struct TransactionReceipt {
    uint64 blockNumber;
    bytes32 blockHash;
    // address contractAddress;
    uint64 cumulativeGasUsed;
    uint64 gasUsed;
    Log[] logs;
    L2ToL1Log[] l2ToL1Logs;
    bool status;
    bytes32 transactionHash;
    uint64 transactionIndex;
}

struct AltTransactionReceipt {
    bytes32 blockHash;
    uint256 blockNumber;
    // address contractAddress;
    uint256 cumulativeGasUsed;
    uint256 effectiveGasPrice;
    address from;
    uint256 gasUsed;
    // AltLog[] logs;
    // L2ToL1Log[] l2ToL1Logs;
    // bytes logsBloom;
    uint256 l1BatchNumber;
    uint256 l1BatchTxIndex;
    uint256 status;
    address to;
    bytes32 transactionHash;
    uint256 transactionIndex;
    uint256 txType;
}
