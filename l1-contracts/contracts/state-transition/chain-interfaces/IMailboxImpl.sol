// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {BridgehubL2TransactionRequest, L2CanonicalTransaction, L2Log, L2Message, TxStatus} from "../../common/Messaging.sol";

/// @title The interface of the ZKsync Mailbox contract that provides functions for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMailboxImpl is IZKChainBase {
    /// @notice Prove that a specific arbitrary-length message was sent in a specific L2 batch number.
    /// @param _batchNumber The executed L2 batch number in which the message appeared.
    /// @param _index The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _message Information about the sent message: sender address, the message itself, tx index in the L2 batch where the message was sent.
    /// @param _proof Merkle proof for inclusion of L2 log that was sent with the message.
    /// @return Boolean specifying whether the proof is valid.
    function proveL2MessageInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view returns (bool);

    /// @notice Prove that a specific L2 log was sent in a specific L2 batch.
    /// @param _batchNumber The executed L2 batch number in which the log appeared.
    /// @param _index The position of the l2log in the L2 logs Merkle tree.
    /// @param _log Information about the sent log.
    /// @param _proof Merkle proof for inclusion of the L2 log.
    /// @return Whether the proof is correct and L2 log is included in batch.
    function proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) external view returns (bool);

    /// @notice Prove that the L1 -> L2 transaction was processed with the specified status.
    /// @param _l2TxHash The L2 canonical transaction hash.
    /// @param _l2BatchNumber The L2 batch number where the transaction was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction.
    /// @param _status The execution status of the L1 -> L2 transaction (true - success & 0 - fail).
    /// @return Whether the proof is correct and the transaction was actually executed with provided status.
    /// NOTE: It may return `false` for incorrect proof, but it doesn't mean that the L1 -> L2 transaction has an opposite status!
    function proveL1ToL2TransactionStatus(
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view returns (bool);

    /// @notice Request execution of L2 transaction through the Bridgehub.
    /// @dev Only accessible from L1, this is getting checked in the Bridgehub.
    /// @param _request the request for the L2 transaction.
    function bridgehubRequestL2Transaction(
        BridgehubL2TransactionRequest calldata _request
    ) external returns (bytes32 canonicalTxHash);

    /// @notice The chain's mailbox receives the tx from the Bridgehub on Gateway.
    /// @param _canonicalTxHash the canonical transaction hash.
    /// @param _expirationTimestamp the expiration timestamp for the transaction.
    function bridgehubRequestL2TransactionOnGateway(bytes32 _canonicalTxHash, uint64 _expirationTimestamp) external;

    /// @notice Request execution of service L2 transaction from L1.
    /// @dev Used for chain configuration. Can be called only by DiamondProxy itself.
    /// @param _contractL2 The L2 receiver address.
    /// @param _l2Calldata The input of the L2 transaction.
    function requestL2ServiceTransaction(
        address _contractL2,
        bytes calldata _l2Calldata
    ) external returns (bytes32 canonicalTxHash);

    /// @notice Pauses deposits on Gateway, needed as migration is only allowed with this timestamp.
    function pauseDepositsOnGateway(uint256 _timestamp) external;

    /// @dev On L1 we have to forward to the Gateway's mailbox which sends to the Bridgehub on the Gateway.
    /// @dev Note that this function is callable by any chain, including potentially malicious ones, so all inputs
    /// need to be validated (or ensured that their validation will happen on L2).
    /// @param _chainId the chainId of the chain.
    /// @param _canonicalTxHash the canonical transaction hash.
    /// @param _expirationTimestamp the expiration timestamp.
    /// @param _baseTokenAmount the base token amount that is sent with the transaction.
    /// @param _getBalanceChange whether a second token is passed with the transaction,
    /// the amount of which will be fetched from the L1 asset tracker. If false it is not fetched for gas savings.
    function requestL2TransactionToGatewayMailboxWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        uint256 _baseTokenAmount,
        bool _getBalanceChange
    ) external returns (bytes32 canonicalTxHash);

    /// @notice Estimates the cost in Ether of requesting execution of an L2 transaction from L1.
    /// @param _gasPrice expected L1 gas price at which the user requests the transaction execution.
    /// @param _l2GasLimit Maximum amount of L2 gas that transaction can consume during execution on L2.
    /// @param _l2GasPerPubdataByteLimit The maximum amount of L2 gas that the operator may charge the user for a single byte of pubdata.
    /// @return The estimated ETH spent on L2 gas for the transaction.
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
    /// @param _batchNumber The batch number of the leaf to be proven.
    /// @param _leafProofMask The leaf proof mask.
    /// @param _leaf The leaf to be proven.
    /// @param _proof The proof.
    function proveL2LeafInclusion(
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) external view returns (bool);

    /// @notice Returns whether deposits are paused on the chain.
    /// @return Whether deposits are paused on the chain.
    function depositsPaused() external view returns (bool);

    /// @notice New priority request event. Emitted when a request is placed into the priority queue.
    /// @param txId Serial number of the priority operation.
    /// @param txHash keccak256 hash of encoded transaction representation.
    /// @param expirationTimestamp Timestamp up to which priority request should be processed.
    /// @param transaction The whole transaction structure that is requested to be executed on L2.
    /// @param factoryDeps An array of bytecodes that were shown in the L1 public data.
    /// Will be marked as known bytecodes in L2.
    event NewPriorityRequest(
        uint256 txId,
        bytes32 txHash,
        uint64 expirationTimestamp,
        L2CanonicalTransaction transaction,
        bytes[] factoryDeps
    );

    /// @notice Indexed new priority request event. Emitted when a request is placed into the priority queue.
    /// @dev We define a new event similar to NewPriorityRequest, as modifying it could break existing indexers.
    /// The indexed txId and txHash helps to simplify external node implementation for fast finality.
    /// @param txId Serial number of the priority operation.
    /// @param txHash keccak256 hash of encoded transaction representation.
    event NewPriorityRequestId(uint256 indexed txId, bytes32 indexed txHash);

    /// @notice New relayed priority request event. It is emitted on a chain that is deployed
    /// on top of the gateway when it receives a request relayed via the Bridgehub.
    /// @dev IMPORTANT: this event most likely will be removed in the future, so
    /// no one should rely on it for indexing purposes.
    /// @param txId Serial number of the priority operation.
    /// @param txHash keccak256 hash of encoded transaction representation.
    /// @param expirationTimestamp Timestamp up to which priority request should be processed.
    event NewRelayedPriorityTransaction(uint256 txId, bytes32 txHash, uint64 expirationTimestamp);
}
