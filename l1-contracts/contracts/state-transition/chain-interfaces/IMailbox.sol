// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {BridgehubL2TransactionRequest, L2CanonicalTransaction} from "../../common/Messaging.sol";

/// @title The interface of the ZKsync Mailbox contract that provides interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMailbox is IZKChainBase {
    /// @notice Request execution of L2 transaction through the Bridgehub.
    /// @dev Only accessible from L1, this is getting checked in the Bridgehub.
    /// @param _request the request for the L2 transaction.
    function bridgehubRequestL2Transaction(
        BridgehubL2TransactionRequest calldata _request
    ) external returns (bytes32 canonicalTxHash);

    /// @notice The chain's mailbox receives the tx from the Bridgehub on Gateway.
    /// @param _canonicalTxHash the canonical transaction hash.
    /// @param _expirationTimestamp Deprecated, always 0.
    function bridgehubRequestL2TransactionOnGateway(bytes32 _canonicalTxHash, uint64 _expirationTimestamp) external;

    /// @notice Request execution of service L2 transaction from L1.
    /// @dev Used for chain configuration. Can be called only by DiamondProxy itself.
    /// @param _contractL2 The L2 receiver address.
    /// @param _l2Calldata The input of the L2 transaction.
    function requestL2ServiceTransaction(
        address _contractL2,
        bytes calldata _l2Calldata
    ) external returns (bytes32 canonicalTxHash);

    /// @dev On L1 we have to forward to the Gateway's mailbox which sends to the Bridgehub on the Gateway.
    /// @dev Note that this function is callable by any chain, including potentially malicious ones, so all inputs
    /// need to be validated (or ensured that their validation will happen on L2).
    /// @param _chainId the chainId of the chain.
    /// @param _canonicalTxHash the canonical transaction hash.
    /// @param _expirationTimestamp Deprecated, always 0.
    function requestL2TransactionToGatewayMailbox(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
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

    /// @notice Returns whether deposits are paused on the chain.
    /// @return Whether deposits are paused on the chain.
    function depositsPaused() external view returns (bool);

    /// @notice New priority request event. Emitted when a request is placed into the priority queue.
    /// @param txId Serial number of the priority operation.
    /// @param txHash keccak256 hash of encoded transaction representation.
    /// @param expirationTimestamp Deprecated, always 0.
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
    /// @param expirationTimestamp Deprecated, always 0.
    event NewRelayedPriorityTransaction(uint256 txId, bytes32 txHash, uint64 expirationTimestamp);
}
