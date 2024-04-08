// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @dev The enum that represents the transaction execution status
/// @param Failure The transaction execution failed
/// @param Success The transaction execution succeeded
enum TxStatus {
    Failure,
    Success
}

/// @dev The log passed from L2
/// @param l2ShardId The shard identifier, 0 - rollup, 1 - porter
/// All other values are not used but are reserved for the future
/// @param isService A boolean flag that is part of the log along with `key`, `value`, and `sender` address.
/// This field is required formally but does not have any special meaning
/// @param txNumberInBatch The L2 transaction number in a Batch, in which the log was sent
/// @param sender The L2 address which sent the log
/// @param key The 32 bytes of information that was sent in the log
/// @param value The 32 bytes of information that was sent in the log
// Both `key` and `value` are arbitrary 32-bytes selected by the log sender
struct L2Log {
    uint8 l2ShardId;
    bool isService;
    uint16 txNumberInBatch;
    address sender;
    bytes32 key;
    bytes32 value;
}

/// @dev An arbitrary length message passed from L2
/// @notice Under the hood it is `L2Log` sent from the special system L2 contract
/// @param txNumberInBatch The L2 transaction number in a Batch, in which the message was sent
/// @param sender The address of the L2 account from which the message was passed
/// @param data An arbitrary length message
struct L2Message {
    uint16 txNumberInBatch;
    address sender;
    bytes data;
}

/// @dev Internal structure that contains the parameters for the writePriorityOp
/// internal function.
/// @param txId The id of the priority transaction.
/// @param l2GasPrice The gas price for the l2 priority operation.
/// @param expirationTimestamp The timestamp by which the priority operation must be processed by the operator.
/// @param request The external calldata request for the priority operation.
struct WritePriorityOpParams {
    uint256 txId;
    uint256 l2GasPrice;
    uint64 expirationTimestamp;
    BridgehubL2TransactionRequest request;
}

/// @dev Structure that includes all fields of the L2 transaction
/// @dev The hash of this structure is the "canonical L2 transaction hash" and can
/// be used as a unique identifier of a tx
/// @param txType The tx type number, depending on which the L2 transaction can be
/// interpreted differently
/// @param from The sender's address. `uint256` type for possible address format changes
/// and maintaining backward compatibility
/// @param to The recipient's address. `uint256` type for possible address format changes
/// and maintaining backward compatibility
/// @param gasLimit The L2 gas limit for L2 transaction. Analog to the `gasLimit` on an
/// L1 transactions
/// @param gasPerPubdataByteLimit Maximum number of L2 gas that will cost one byte of pubdata
/// (every piece of data that will be stored on L1 as calldata)
/// @param maxFeePerGas The absolute maximum sender willing to pay per unit of L2 gas to get
/// the transaction included in a Batch. Analog to the EIP-1559 `maxFeePerGas` on an L1 transactions
/// @param maxPriorityFeePerGas The additional fee that is paid directly to the validator
/// to incentivize them to include the transaction in a Batch. Analog to the EIP-1559
/// `maxPriorityFeePerGas` on an L1 transactions
/// @param paymaster The address of the EIP-4337 paymaster, that will pay fees for the
/// transaction. `uint256` type for possible address format changes and maintaining backward compatibility
/// @param nonce The nonce of the transaction. For L1->L2 transactions it is the priority
/// operation Id
/// @param value The value to pass with the transaction
/// @param reserved The fixed-length fields for usage in a future extension of transaction
/// formats
/// @param data The calldata that is transmitted for the transaction call
/// @param signature An abstract set of bytes that are used for transaction authorization
/// @param factoryDeps The set of L2 bytecode hashes whose preimages were shown on L1
/// @param paymasterInput The arbitrary-length data that is used as a calldata to the paymaster pre-call
/// @param reservedDynamic The arbitrary-length field for usage in a future extension of transaction formats
struct L2CanonicalTransaction {
    uint256 txType;
    uint256 from;
    uint256 to;
    uint256 gasLimit;
    uint256 gasPerPubdataByteLimit;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    uint256 paymaster;
    uint256 nonce;
    uint256 value;
    // In the future, we might want to add some
    // new fields to the struct. The `txData` struct
    // is to be passed to account and any changes to its structure
    // would mean a breaking change to these accounts. To prevent this,
    // we should keep some fields as "reserved"
    // It is also recommended that their length is fixed, since
    // it would allow easier proof integration (in case we will need
    // some special circuit for preprocessing transactions)
    uint256[4] reserved;
    bytes data;
    bytes signature;
    uint256[] factoryDeps;
    bytes paymasterInput;
    // Reserved dynamic type for the future use-case. Using it should be avoided,
    // But it is still here, just in case we want to enable some additional functionality
    bytes reservedDynamic;
}

/// @param sender The sender's address.
/// @param contractAddressL2 The address of the contract on L2 to call.
/// @param valueToMint The amount of base token that should be minted on L2 as the result of this transaction.
/// @param l2Value The msg.value of the L2 transaction.
/// @param l2Calldata The calldata for the L2 transaction.
/// @param l2GasLimit The limit of the L2 gas for the L2 transaction
/// @param l2GasPerPubdataByteLimit The price for a single pubdata byte in L2 gas.
/// @param factoryDeps The array of L2 bytecodes that the tx depends on.
/// @param refundRecipient The recipient of the refund for the transaction on L2. If the transaction fails, then
/// this address will receive the `l2Value`.
struct BridgehubL2TransactionRequest {
    address sender;
    address contractL2;
    uint256 mintValue;
    uint256 l2Value;
    bytes l2Calldata;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    bytes[] factoryDeps;
    address refundRecipient;
}
