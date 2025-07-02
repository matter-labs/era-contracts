// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

struct Broadcast {
    uint256 chain;
    string commit;
    Library[] libraries;
    string[] pending;
    Receipt2[] receipts;
    Return returnValues;
    uint256 timestamp;
    Transaction[] transactions;
}

struct Transaction {
    string[] additionalContracts;
    bytes32[] arguments;
    address contractAddress;
    string functionKey;
    bytes32 hash;
    bool isFixedGasLimit;
    TransactionData transaction;
    string transactionType;
}

struct Return {
    bytes32 blockHash;
    // Add return fields if needed based on the JSON structure
}

struct TransactionData {
    address from;
    address to;
    uint256 gas;
    uint256 value;
    bytes input;
    uint256 nonce;
    uint256 chainId;
    ZkSync zksync;
}

struct ZkSync {
    bytes[] factoryDeps;
    // bytes paymasterData;
}

struct Receipt2 {
    uint256 status;
    uint256 cumulativeGasUsed;
    Log[] logs;
    bytes logsBloom;
    uint256 typeSelector;
    bytes32 transactionHash;
    uint256 transactionIndex;
    bytes32 blockHash;
    uint256 blockNumber;
    address contractAddress;
    uint256 l1BatchNumber;
    uint256 l1BatchTxIndex;
    L2ToL1Log[] l2ToL1Logs;
    uint256 gasUsed;
    uint256 effectiveGasPrice;
    address from;
    address to;
}

struct Log {
    address address_;
    bytes32[] topics;
    bytes data;
    bytes32 blockHash;
    uint256 blockNumber;
    uint256 blockTimestamp;
    bytes32 transactionHash;
    uint256 transactionIndex;
    uint256 logIndex;
    bool removed;
}

struct L2ToL1Log {
    bytes32 blockHash;
    uint256 blockNumber;
    uint256 l1BatchNumber;
    uint256 logIndex;
    uint256 transactionIndex;
    bytes32 transactionHash;
    uint256 transactionLogIndex;
    uint256 txIndexInL1Batch;
    uint256 shardId;
    bool isService;
    address sender;
    bytes32 key;
    bytes32 value;
}

struct Library {
    uint256 version;
    // Add library fields if needed based on the JSON structure
}

