// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMessageVerification} from "../../common/interfaces/IMessageVerification.sol";
import {FinalizeL1DepositParams, L2Log, L2Message, TxStatus} from "../../common/Messaging.sol";

/**
 * @title MockL2MessageVerification
 * @notice Mock implementation of L2MessageVerification for Anvil testing
 * @dev Always returns true for message inclusion proofs to bypass L1 settlement in local testing
 */
contract MockL2MessageVerification is IMessageVerification {
    /// @notice Always returns true for Anvil testing - bypasses actual Merkle proof verification
    function proveL2MessageInclusionShared(
        uint256 /* _chainId */,
        uint256 /* _blockOrBatchNumber */,
        uint256 /* _index */,
        L2Message memory /* _message */,
        bytes32[] calldata /* _proof */
    ) external pure override returns (bool) {
        // For Anvil testing, always return true to bypass L1 settlement verification
        return true;
    }

    /// @notice Always returns true for Anvil testing - bypasses actual log inclusion verification
    function proveL2LogInclusionShared(
        uint256 /* _chainId */,
        uint256 /* _blockOrBatchNumber */,
        uint256 /* _index */,
        L2Log calldata /* _log */,
        bytes32[] calldata /* _proof */
    ) external pure override returns (bool) {
        // For Anvil testing, always return true to bypass L1 settlement verification
        return true;
    }

    /// @notice Always returns true for Anvil testing - bypasses actual leaf inclusion verification
    function proveL2LeafInclusionShared(
        uint256 /* _chainId */,
        uint256 /* _blockOrBatchNumber */,
        uint256 /* _leafProofMask */,
        bytes32 /* _leaf */,
        bytes32[] calldata /* _proof */
    ) external pure override returns (bool) {
        // For Anvil testing, always return true to bypass L1 settlement verification
        return true;
    }

    /// @notice Always returns true for Anvil testing - bypasses actual transaction status verification
    function proveL1ToL2TransactionStatusShared(
        uint256 /* _chainId */,
        bytes32 /* _l2TxHash */,
        uint256 /* _l2BatchNumber */,
        uint256 /* _l2MessageIndex */,
        uint16 /* _l2TxNumberInBatch */,
        bytes32[] calldata /* _merkleProof */,
        TxStatus /* _status */
    ) external pure override returns (bool) {
        // For Anvil testing, always return true to bypass L1 settlement verification
        return true;
    }

    /// @notice Always returns true for Anvil testing - bypasses actual deposit params verification
    function proveL1DepositParamsInclusion(
        FinalizeL1DepositParams calldata /* _finalizeWithdrawalParams */
    ) external pure override returns (bool) {
        // For Anvil testing, always return true to bypass L1 settlement verification
        return true;
    }
}
