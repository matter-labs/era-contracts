// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @title IBaseTokenHolder
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the BaseTokenHolder contract that holds the chain's base token reserves.
interface IBaseTokenHolder {
    /// @notice Gives out base tokens from the holder to a recipient.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external;

    /// @notice Initiates withdrawal of the base token to L1.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable;

    /// @notice Initiates withdrawal of the base token to L1 with additional data.
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data to be sent to L1 with the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable;
}
