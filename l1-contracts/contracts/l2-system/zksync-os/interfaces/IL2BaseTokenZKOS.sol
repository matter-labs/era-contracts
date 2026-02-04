// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @title IL2BaseTokenZKOS
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the L2BaseToken contract on ZK OS chains.
/// @dev This is a minimal interface that only exposes withdrawal functionality.
/// @dev Unlike Era, ZK OS uses native ETH transfers and doesn't need balance management functions.
interface IL2BaseTokenZKOS {
    /// @notice Emitted when a withdrawal is initiated
    event Withdrawal(address indexed _l2Sender, address indexed _l1Receiver, uint256 _amount);

    /// @notice Emitted when a withdrawal with message is initiated
    event WithdrawalWithMessage(
        address indexed _l2Sender,
        address indexed _l1Receiver,
        uint256 _amount,
        bytes _additionalData
    );

    /// @notice Initiate the withdrawal of the base token.
    /// @dev Funds will be available to claim on L1 via `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable;

    /// @notice Initiate the withdrawal of the base token with an additional message.
    /// @dev Funds will be available to claim on L1 via `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data to be sent to L1 with the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable;

    /// @notice Initializes the BaseTokenHolder's balance during genesis or V31 upgrade.
    /// @dev Mints 2^127 - 1 tokens and transfers them to BaseTokenHolder.
    function initializeBaseTokenHolderBalance() external;
}
