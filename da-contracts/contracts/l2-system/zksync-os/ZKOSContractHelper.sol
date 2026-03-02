// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Interface for the contract that is used to simulate Base Token on L2.
 */
interface IBaseToken {
    /// @notice Allows the withdrawal of Base Token to a given L1 receiver.
    /// @param _l1Receiver The address on L1 to receive the withdrawn Base Token.
    function withdraw(address _l1Receiver) external payable;

    /// @notice Allows the withdrawal of Base Token to a given L1 receiver along with an additional message.
    /// @param _l1Receiver     The address on L1 to receive the withdrawn Base Token.
    /// @param _additionalData Additional message or data to be sent alongside the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes memory _additionalData) external payable;

    /// @notice Emitted when a base-token withdrawal is initiated.
    /// @param _l2Sender    The L2 address that initiated the withdrawal.
    /// @param _l1Receiver  The L1 address that will receive the withdrawn Base Token.
    /// @param _amount      The amount of Base Token (in wei) withdrawn.
    event Withdrawal(address indexed _l2Sender, address indexed _l1Receiver, uint256 _amount);

    /// @notice Emitted when a base-token withdrawal with an additional message is initiated.
    /// @param _l2Sender       The L2 address that initiated the withdrawal.
    /// @param _l1Receiver     The L1 address that will receive the withdrawn Base Token.
    /// @param _amount         The amount of Base Token (in wei) withdrawn.
    /// @param _additionalData Arbitrary data/message forwarded alongside the withdrawal.
    event WithdrawalWithMessage(
        address indexed _l2Sender,
        address indexed _l1Receiver,
        uint256 _amount,
        bytes _additionalData
    );
}
