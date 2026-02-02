// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

bytes1 constant BUNDLE_IDENTIFIER = 0x01;
bytes1 constant INTEROP_BUNDLE_VERSION = 0x01;
bytes1 constant INTEROP_CALL_VERSION = 0x01;

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

/// @dev Internal structure that contains the parameters for the writePriorityOp internal function.
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
/// @param contractL2 The address of the contract on L2 to call.
/// @param mintValue The amount of base token that should be minted on L2 as the result of this transaction.
/// @param l2Value The msg.value of the L2 transaction.
/// @param l2Calldata The calldata for the L2 transaction.
/// @param l2GasLimit The limit of the L2 gas for the L2 transaction
/// @param l2GasPerPubdataByteLimit The price for a single pubdata byte in L2 gas.
/// @param factoryDeps The array of L2 bytecodes that the tx depends on.
/// @param refundRecipient The recipient of the refund for the transaction on L2. If the transaction fails, then
/// this address will receive the `l2Value`.
// solhint-disable-next-line gas-struct-packing
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

/// @dev The structure that contains the parameters for the message root
/// @param chainId The chain id of the dependency chain
/// @param blockOrBatchNumber The block number or the batch number where the message root was created
/// For proof based interop it is block number. For commit based interop it is batch number.
/// @param sides The sides of the dynamic incremental merkle tree emitted in the L2ToL1Messenger for precommit based interop
/// For proof and commit based interop, the sides contain a single root.
struct InteropRoot {
    uint256 chainId;
    uint256 blockOrBatchNumber;
    // We are double overloading this. The sides of the dynamic incremental merkle tree normally contains the root, as well as the sides of the tree.
    // Second overloading: if the length is 1, we are importing a chainBatchRoot/messageRoot instead of sides.
    bytes32[] sides;
}

/// @param chainId The chain ID of the transaction to check.
/// @param l2BatchNumber The L2 batch number where the withdrawal was processed.
/// @param l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
/// @param l2Sender The address of the message sender on L2 (base token system contract address or asset handler)
/// @param l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent.
/// @param message The L2 withdraw data, stored in an L2 -> L1 message.
/// @param merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
struct FinalizeL1DepositParams {
    uint256 chainId;
    uint256 l2BatchNumber;
    uint256 l2MessageIndex;
    address l2Sender;
    uint16 l2TxNumberInBatch;
    bytes message;
    bytes32[] merkleProof;
}

/// @dev Struct used to define parameters for adding a single call in an interop bundle.
/// @param to ERC-7930 address to call on the destination chain. Note, that it will have empty ChainReference.
///           This is due to the fact that chain ID is always provided on a bundle level, as a destination chain ID.
///           And in case of sendMessage the chain ID is also provided via the sendMessage interface, so it's redundant to store it here.
/// @param data Calldata payload to send to `to` address on the destination chain.
/// @param callAttributes EIP-7786 Attributes.
struct InteropCallStarter {
    bytes to;
    bytes data;
    bytes[] callAttributes;
}

/// @dev Internal representation of an InteropCallStarter after parsing its parameters.
/// @param to Address to call on the destination chain.
/// @param data Calldata payload to send.
/// @param callAttributes EIP-7786 Attributes.
struct InteropCallStarterInternal {
    address to;
    bytes data;
    CallAttributes callAttributes;
}

/// @param interopCallValue Base token value on destination chain to send for interop call.
/// @param indirectCall An indirect call first calls a contract as specified by the call starter which returns an actual call starter that will be used to form an interop call. In particular, this is used for interop token transfers. In contrast, a direct call uses the call starter to form an interop call.
/// @param indirectCallMessageValue Base token value on sending chain to send for indirect call.
struct CallAttributes {
    uint256 interopCallValue;
    bool indirectCall;
    uint256 indirectCallMessageValue;
}

/// @param executionAddress ERC-7930 Address allowed to execute the bundle on the destination chain. If the byte array is empty then execution is permissionless.
/// @param unbundlerAddress ERC-7930 Address allowed to unbundle the bundle on the destination chain. Note, that it is required to be nonempty, unlike `executionAddress`.
/// @param useFixedFee If true, user pays fixed ZK fees instead of base token fees controlled by chain operator.
///                    This is a bundle-level attribute - all calls within a bundle share the same fee mode.
///                    Users are free to choose which fee mode to use when creating their bundle.
///                    In more details, any user of interop functionality is able to choose between two fee options:
///                    - Fixed fee in ZK (ZK_INTEROP_FEE constant in InteropCenter). User pays this fee directly in ZK tokens via ERC20 transfer.
///                    - Dynamic fee in base token of source chain where the interop is initiated. This value is fully under control of chain operator via interopProtocolFee in InteropCenter.
///                    In any case, gateway settlement fees (gatewaySettlementFee per call, set by governance in GWAssetTracker) are charged from the settlementFeePayer address
///                    (specified in executeBatchesSharedBridge) when the chain settles on Gateway via processLogsAndMessages(). The settlementFeePayer must have pre-approved
///                    GWAssetTracker to spend wrapped ZK tokens.
///                    Note on ZK-as-base-token chains: On chains where ZK is the base token, useFixedFee=true still requires wrapped ZK tokens
///                    (paid via ERC20 transfer), while useFixedFee=false accepts native ZK via msg.value. This is intentional behavior.
///                    IMPORTANT: useFixedFee=true requires ZK token to be bridged to the source chain. If ZK token is not yet available
///                    in the chain's NativeTokenVault, the transaction will revert with ZKTokenNotAvailable().
struct BundleAttributes {
    bytes executionAddress;
    bytes unbundlerAddress;
    bool useFixedFee;
}

/// @dev A single call.
/// @param version Version of the InteropCall.
/// @param shadowAccount If true, execute via a shadow account, otherwise normal. In current release always false, as it's not yet implemented.
///                      Shadow accounts help with interop when `to` doesn't support 7786. In this case, a "shadow" account could be deployed, allowing
///                      the user to hold funds securely on the destination chain, and interact with anything on destination chain using this shadow account.
/// @param to Destination contract address on the target chain.
/// @param from Original sender address that initiated the call.
/// @param value Amount of base token to send with the call.
/// @param data Calldata payload for the call.
struct InteropCall {
    bytes1 version;
    bool shadowAccount;
    address to;
    address from;
    uint256 value;
    bytes data;
}

/// @dev Execution status of an individual call within a bundle.
/// @param Unprocessed Call not yet processed.
/// @param Executed Call was successfully executed.
/// @param Cancelled Call was cancelled during unbundling.
enum CallStatus {
    Unprocessed,
    Executed,
    Cancelled
}

/// @dev A set of `InteropCall`s to send to another chain.
/// @param version Version of the InteropBundle.
/// @param destinationChainId ChainId of the target chain.
/// @param interopBundleSalt Salt of the interopBundle. It's required to ensure that all bundles have distinct hashes.
///                          It's equal to the keccak256(abi.encodePacked(senderOfTheBundle, NumberOfBundleSentByTheSender))
/// @param calls Array of InteropCall structs to execute.
/// @param bundleAttributes Bundle execution and unbundling attributes.
struct InteropBundle {
    bytes1 version;
    uint256 sourceChainId;
    uint256 destinationChainId;
    bytes32 interopBundleSalt;
    InteropCall[] calls;
    BundleAttributes bundleAttributes;
}

/// @dev Processing status of an `InteropBundle`.
/// @param Unreceived Bundle is not processed in any way yet.
/// @param Verified Bundle inclusion proof accepted, but not processed.
/// @param FullyExecuted All calls in the bundle have been executed atomically via executeBundle.
/// @param Unbundled Bundle was processed via unbundling flow.
enum BundleStatus {
    Unreceived,
    Verified,
    FullyExecuted,
    Unbundled
}

/// @dev Inclusion proof for a cross-chain message payload (bundle) coming from L2→L1.
/// @param chainId Source chain identifier.
/// @param l1BatchNumber Batch number on L1 where the message root was committed.
/// @param l2MessageIndex Position in the L2 logs Merkle tree of this message.
/// @param message The raw L2 message payload (including `BUNDLE_IDENTIFIER` prefix).
/// @param proof Merkle‐proof for verifying the message inclusion.
struct MessageInclusionProof {
    uint256 chainId;
    uint256 l1BatchNumber;
    uint256 l2MessageIndex;
    L2Message message;
    bytes32[] proof;
}

/// @dev Inclusion proof for a single L2 log entry passed to L1.
/// @param chainId Source chain identifier.
/// @param l1BatchNumber Batch number on L1 where the message root was committed.
/// @param l2LogIndex Position in the L2 logs Merkle tree of this log.
/// @param log The decoded `L2Log` entry.
/// @param proof Merkle‐proof for verifying the log inclusion.
struct LogInclusionProof {
    uint256 chainId;
    uint256 l1BatchNumber;
    uint256 l2LogIndex;
    L2Log log;
    bytes32[] proof;
}

/// @dev Generic inclusion proof for an arbitrary 32‐byte leaf in the L2→L1 Merkle tree.
/// @param chainId Source chain identifier.
/// @param l1BatchNumber Batch number on L1 where the message root was committed.
/// @param l2LeafProofMask Bitmask indicating this leaf’s position, given as integer.
/// @param leaf The 32-byte leaf whose inclusion is being proven.
/// @param proof Merkle‐proof for verifying the leaf inclusion.
struct LeafInclusionProof {
    uint256 chainId;
    uint256 l1BatchNumber;
    uint256 l2LeafProofMask;
    bytes32 leaf;
    bytes32[] proof;
}

struct ProofData {
    uint256 settlementLayerChainId;
    uint256 settlementLayerBatchNumber;
    uint256 settlementLayerBatchRootMask;
    uint256 batchLeafProofLen;
    bytes32 batchSettlementRoot;
    bytes32 chainIdLeaf;
    uint256 ptr;
    bool finalProofNode;
}

struct TokenBalanceMigrationData {
    bytes1 version;
    bool isL1ToGateway;
    address originToken;
    uint256 chainId;
    bytes32 assetId;
    uint256 tokenOriginChainId;
    uint256 amount;
    uint256 chainMigrationNumber;
    uint256 assetMigrationNumber;
}

struct BalanceChange {
    bytes1 version;
    address originToken;
    bytes32 baseTokenAssetId;
    uint256 baseTokenAmount;
    bytes32 assetId;
    uint256 amount;
    uint256 tokenOriginChainId;
}

struct AssetBalanceChange {
    bytes32 assetId;
    uint256 amount;
}

struct InteropBalanceChange {
    bytes1 version;
    uint256 baseTokenAmount;
    AssetBalanceChange[] assetBalanceChanges;
}

/// @param _chainId The ZK chain id to which deposit was initiated.
/// @param _depositSender The address of the entity that initiated the deposit.
/// @param _assetId The unique identifier of the deposited L1 token.
/// @param _assetData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
/// @param _l2TxHash The L2 transaction hash.
/// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
/// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
/// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
/// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
/// @param _txStatus The status of the transaction.
struct ConfirmTransferResultData {
    uint256 _chainId;
    address _depositSender;
    uint16 _l2TxNumberInBatch;
    TxStatus _txStatus;
    bytes32 _assetId;
    bytes _assetData;
    bytes32 _l2TxHash;
    uint256 _l2BatchNumber;
    uint256 _l2MessageIndex;
    bytes32[] _merkleProof;
}

struct TokenMetadata {
    string name;
    string symbol;
    uint256 decimals;
}

struct TokenBridgingData {
    bytes32 assetId;
    uint256 originChainId;
    /// The address of the base token on the origin chain.
    address originToken;
}
