// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @title IBaseTokenHolder
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the BaseTokenHolder contract that holds the chain's base token reserves.
/// @dev This contract replaces the mint/burn approach with a transfer-based approach for better EVM compatibility.
/// Instead of minting base tokens during deposits/interops, tokens are transferred from this holder contract.
/// This makes the system more compatible with standard EVM tooling like Foundry.
interface IBaseTokenHolder {
    /// @notice Emitted when base tokens are given out from the holder to a recipient.
    /// @param to The address receiving the base tokens.
    /// @param amount The amount of base tokens transferred.
    event BaseTokenGiven(address indexed to, uint256 amount);

    /// @notice Emitted when base tokens are received back into the holder (e.g., during withdrawals).
    /// @param from The address sending the base tokens back.
    /// @param amount The amount of base tokens received.
    event BaseTokenReceived(address indexed from, uint256 amount);

    /// @notice Gives out base tokens from the holder to a recipient.
    /// @dev Can only be called by authorized callers (bootloader, InteropHandler).
    /// @dev This replaces the mint operation - tokens are transferred instead of minted.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external;

    /// @notice Receives base tokens back into the holder.
    /// @dev This replaces the burn operation - tokens are transferred back instead of burned.
    /// @dev Called during withdrawals to return tokens to the holder.
    function receive_() external payable;
}
