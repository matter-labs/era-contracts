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

    /// @notice Receives base tokens and initiates bridging by notifying L2AssetTracker.
    /// @dev Called by InteropHandler, InteropCenter, NativeTokenVault, and L2BaseToken during bridging operations.
    function burnAndStartBridging() external payable;
}
