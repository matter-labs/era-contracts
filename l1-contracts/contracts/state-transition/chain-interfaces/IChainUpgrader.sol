// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title Interface for upgrading a ZK chain from a specific protocol version.
/// @dev Shared by IAdmin (diamond facet) and IValidatorTimelock to ensure signature parity at compile time.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainUpgrader {
    /// @notice Perform the upgrade from the current protocol version.
    /// @dev The cut is NOT an argument: the chain reads it from its own ChainTypeManager, which
    ///      composed it from the transition it committed for this edge. A caller therefore cannot
    ///      substitute one.
    /// @param _chainAddress The address of the chain being upgraded.
    /// @param _protocolVersion The current protocol version from which upgrade is executed.
    function upgradeChainFromVersion(address _chainAddress, uint256 _protocolVersion) external;
}
