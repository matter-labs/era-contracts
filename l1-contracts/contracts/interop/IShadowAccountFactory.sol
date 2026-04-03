// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IShadowAccountFactory
/// @notice Interface for the ShadowAccount deployer factory.
/// @dev Deploys ShadowAccount instances via CREATE2 with deterministic addresses.
interface IShadowAccountFactory {
    /// @notice Emitted when a new ShadowAccount is deployed.
    event ShadowAccountDeployed(address indexed account, bytes owner);

    /// @notice Returns the existing ShadowAccount for the given owner, or deploys one if none exists.
    /// @param _owner ERC-7930 encoded address of the owner on the home chain.
    /// @return account Address of the ShadowAccount.
    function getOrDeployShadowAccount(bytes calldata _owner) external returns (address account);

    /// @notice Predicts the deterministic address of the ShadowAccount for a given owner.
    /// @param _owner ERC-7930 encoded address of the owner on the home chain.
    /// @return predicted The predicted address.
    function predictAddress(bytes calldata _owner) external view returns (address predicted);
}
