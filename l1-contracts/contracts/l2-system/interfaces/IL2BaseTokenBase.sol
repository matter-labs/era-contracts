// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @title IL2BaseTokenBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Base interface for L2 Base Token contracts (shared between Era and ZK OS).
/// @dev This interface defines the common withdrawal functionality.
interface IL2BaseTokenBase {
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
    /// @dev The implementation varies between Era and ZK OS but both require this initialization.
    function initializeBaseTokenHolderBalance() external;
}
