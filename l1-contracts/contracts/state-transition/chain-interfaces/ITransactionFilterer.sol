// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title The interface of the L1 -> L2 transaction filterer.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ITransactionFilterer {
    /// @notice Check if the transaction is allowed
    /// @param sender The sender of the transaction
    /// @param contractL2 The L2 receiver address
    /// @param mintValue The value of the L1 transaction
    /// @param l2Value The msg.value of the L2 transaction
    /// @param l2Calldata The calldata of the L2 transaction
    /// @param refundRecipient The address to refund the excess value
    /// @return Whether the transaction is allowed
    function isTransactionAllowed(
        address sender,
        address contractL2,
        uint256 mintValue,
        uint256 l2Value,
        bytes memory l2Calldata,
        address refundRecipient
    ) external view returns (bool);
}
