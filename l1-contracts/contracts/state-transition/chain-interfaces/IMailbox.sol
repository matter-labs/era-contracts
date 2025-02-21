// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {L2CanonicalTransaction, L2Log, L2Message, TxStatus, BridgehubL2TransactionRequest} from "../../common/Messaging.sol";

/// @title The interface of the ZKsync Mailbox contract that provides interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMailbox is IZKChainBase {
    /// @notice Prove that a specific arbitrary-length message was sent in a specific L2 batch number
    /// @param _batchNumber The executed L2 batch number in which the message appeared
    /// @param _index The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _message Information about the sent message: sender address, the message itself, tx index in the L2 batch where the message was sent
    /// @param _proof Merkle proof for inclusion of L2 log that was sent with the message
    /// @return Whether the proof is valid
    function proveL2MessageInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view returns (bool);

    /// @notice Prove that a specific L2 log was sent in a specific L2 batch
    /// @param _batchNumber The executed L2 batch number in which the log appeared
    /// @param _index The position of the l2log in the L2 logs Merkle tree
    /// @param _log Information about the sent log
    /// @param _proof Merkle proof for inclusion of the L2 log
    /// @return Whether the proof is correct and L2 log is included in batch
    function proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view returns (bool);

    /// @notice Prove that the L1 -> L2 transaction was processed with the specified status.
    /// @param _l2TxHash The L2 canonical transaction hash
    /// @param _l2BatchNumber The L2 batch number where the transaction was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction
    /// @param _status The execution status of the L1 -> L2 transaction (true - success & 0 - fail)
    /// @return Whether the proof is correct and the transaction was actually executed with provided status
    /// NOTE: It may return `false` for incorrect proof, but it doesn't mean that the L1 -> L2 transaction has an opposite status!
    function proveL1ToL2TransactionStatus(
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view returns (bool);

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeEthWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;

    /// @notice Request execution of L2 transaction from L1.
    /// @param _contractL2 The L2 receiver address
    /// @param _l2Value `msg.value` of L2 transaction
    /// @param _calldata The input of the L2 transaction
    /// @param _l2GasLimit Maximum amount of L2 gas that transaction can consume during execution on L2
    /// @param _l2GasPerPubdataByteLimit The maximum amount L2 gas that the operator may charge the user for single byte of pubdata.
    /// @param _factoryDeps An array of L2 bytecodes that will be marked as known on L2
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @dev If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
    /// Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses out of control.
    /// - If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will be sent to the `msg.sender` address.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be sent to the aliased `msg.sender` address.
    /// @dev The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds are controllable,
    /// since address aliasing to the from address for the L2 tx will be applied if the L1 `msg.sender` is a contract.
    /// Without address aliasing for L1 contracts as refund recipients they would not be able to make proper L2 tx requests
    /// through the Mailbox to use or withdraw the funds from L2, and the funds would be lost.
    /// @return canonicalTxHash The hash of the requested L2 transaction. This hash can be used to follow the transaction status
    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable returns (bytes32 canonicalTxHash);

    /// @notice when requesting transactions through the bridgehub
    function bridgehubRequestL2Transaction(
        BridgehubL2TransactionRequest calldata _request
    ) external returns (bytes32 canonicalTxHash);

    /// @dev On the Gateway the chain's mailbox receives the tx from the bridgehub.
    function bridgehubRequestL2TransactionOnGateway(bytes32 _canonicalTxHash, uint64 _expirationTimestamp) external;

    /// @notice Request execution of service L2 transaction from L1.
    /// @dev Used for chain configuration. Can be called only by DiamondProxy itself.
    /// @param _contractL2 The L2 receiver address
    /// @param _l2Calldata The input of the L2 transaction
    function requestL2ServiceTransaction(
        address _contractL2,
        bytes calldata _l2Calldata
    ) external returns (bytes32 canonicalTxHash);

    /// @dev On L1 we have to forward to the Gateway's mailbox which sends to the Bridgehub on the Gw
    /// @param _chainId the chainId of the chain
    /// @param _canonicalTxHash the canonical transaction hash
    /// @param _expirationTimestamp the expiration timestamp
    function requestL2TransactionToGatewayMailbox(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external returns (bytes32 canonicalTxHash);

    /// @notice Estimates the cost in Ether of requesting execution of an L2 transaction from L1
    /// @param _gasPrice expected L1 gas price at which the user requests the transaction execution
    /// @param _l2GasLimit Maximum amount of L2 gas that transaction can consume during execution on L2
    /// @param _l2GasPerPubdataByteLimit The maximum amount of L2 gas that the operator may charge the user for a single byte of pubdata.
    /// @return The estimated ETH spent on L2 gas for the transaction
    function l2TransactionBaseCost(
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);

    /// @dev Proves that a certain leaf was included as part of the log merkle tree.
    /// @dev Warning: this function does not enforce any additional checks on the structure
    /// of the leaf. This means that it can accept intermediate nodes of the Merkle tree as a `_leaf` as
    /// well as the default "empty" leaves. It is the responsibility of the caller to ensure that the
    /// `_leaf` is a hash of a valid leaf.
    function proveL2LeafInclusion(
        uint256 _batchNumber,
        uint256 _batchRootMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) external view returns (bool);

    /// @notice transfer Eth to shared bridge as part of migration process
    // function transferEthToSharedBridge() external;

    // function relayTxSL(
    //     address _to,
    //     L2CanonicalTransaction memory _transaction,
    //     bytes[] memory _factoryDeps,
    //     bytes32 _canonicalTxHash,
    //     uint64 _expirationTimestamp
    // ) external;

    // function freeAcceptTx(
    //     L2CanonicalTransaction memory _transaction,
    //     bytes[] memory _factoryDeps,
    //     bytes32 _canonicalTxHash,
    //     uint64 _expirationTimestamp
    // ) external;

    // function acceptFreeRequestFromBridgehub(BridgehubL2TransactionRequest calldata _request) external;

    /// @notice New priority request event. Emitted when a request is placed into the priority queue
    /// @param txId Serial number of the priority operation
    /// @param txHash keccak256 hash of encoded transaction representation
    /// @param expirationTimestamp Timestamp up to which priority request should be processed
    /// @param transaction The whole transaction structure that is requested to be executed on L2
    /// @param factoryDeps An array of bytecodes that were shown in the L1 public data.
    /// Will be marked as known bytecodes in L2
    event NewPriorityRequest(
        uint256 txId,
        bytes32 txHash,
        uint64 expirationTimestamp,
        L2CanonicalTransaction transaction,
        bytes[] factoryDeps
    );

    /// @notice New relayed priority request event. It is emitted on a chain that is deployed
    /// on top of the gateway when it receives a request relayed via the Bridgehub.
    /// @dev IMPORTANT: this event most likely will be removed in the future, so
    /// no one should rely on it for indexing purposes.
    /// @param txId Serial number of the priority operation
    /// @param txHash keccak256 hash of encoded transaction representation
    /// @param expirationTimestamp Timestamp up to which priority request should be processed
    event NewRelayedPriorityTransaction(uint256 txId, bytes32 txHash, uint64 expirationTimestamp);
}
