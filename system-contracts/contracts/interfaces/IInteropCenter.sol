// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IInteropCenter {
    /// @notice Sets the base token fee per interop call.
    /// @dev Only callable by the bootloader as a system transaction, operator-controlled.
    /// @param _fee New fee amount in base token wei.
    function setInteropFee(uint256 _fee) external;
}
