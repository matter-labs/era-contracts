// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title Interface for applying a ZK chain's scheduled configuration update.
/// @dev Shared by IChainConfig (diamond facet) and IValidatorTimelock to ensure signature parity at compile time.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainConfigApplier {
    /// @notice Applies the configuration update the chain admin scheduled, once its timestamp has passed.
    /// See {protocol-docs/chain-config.md#scheduled-configuration-updates}.
    /// @param _chainAddress The address of the chain being updated.
    function applyChainConfigUpdate(address _chainAddress) external;
}
