// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {FinalizeL1DepositParams, L2Log, L2Message, TxStatus} from "../Messaging.sol";

/// @title The interface of the ZKsync MessageVerification contract that can be used to prove L2 message inclusion.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMessageVerification {
    /// @notice Prove that a specific arbitrary-length message was sent in a specific L2 batch/block number.
    /// @param _chainId The chain id of the L2 where the message comes from.
    /// @param _blockOrBatchNumber The executed L2 batch/block number in which the message appeared.
    /// @param _index The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _message Information about the sent message: sender address, the message itself, tx index in the L2 batch where the message was sent.
    /// @param _proof Merkle proof for inclusion of L2 log that was sent with the message.
    /// @return Boolean specifying whether the proof is valid.
    function proveL2MessageInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view returns (bool);

    /// @notice Prove that a specific L2 log was sent in a specific L2 batch.
    /// @param _chainId The chain id of the L2 where the log comes from.
    /// @param _blockOrBatchNumber The executed L2 batch/block number in which the log appeared.
    /// @param _index The position of the l2log in the L2 logs Merkle tree.
    /// @param _log Information about the sent log.
    /// @param _proof Merkle proof for inclusion of the L2 log.
    /// @return Whether the proof is correct and L2 log is included in batch.
    function proveL2LogInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) external view returns (bool);

    /// @dev Proves that a certain leaf was included as part of the log merkle tree.
    /// @dev Warning: this function does not enforce any additional checks on the structure
    /// of the leaf. This means that it can accept intermediate nodes of the Merkle tree as a `_leaf` as
    /// well as the default "empty" leaves. It is the responsibility of the caller to ensure that the
    /// `_leaf` is a hash of a valid leaf.
    /// @param _chainId The chain id of the L2 where the leaf comes from.
    /// @param _blockOrBatchNumber The batch/block number of the leaf to be proven.
    /// @param _leafProofMask The leaf proof mask.
    /// @param _leaf The leaf to be proven.
    /// @param _proof The proof.
    function proveL2LeafInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
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
    function proveL1ToL2TransactionStatusShared(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view returns (bool);

    /// @notice Prove that the L2 -> L1 transaction was processed with the specified status.
    function proveL1DepositParamsInclusion(
        FinalizeL1DepositParams calldata _finalizeWithdrawalParams
    ) external view returns (bool success);
}
