// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @notice The interface for the permanent restriction contract.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IPermanentRestriction {
    /// @notice Emitted when the implementation is allowed or disallowed.
    event AdminImplementationAllowed(bytes32 indexed implementationHash, bool isAllowed);

    /// @notice Emitted when a certain calldata is allowed or disallowed.
    event AllowedDataChanged(bytes data, bool isAllowed);

    /// @notice Emitted when the selector is labeled as validated or not.
    event SelectorValidationChanged(bytes4 indexed selector, bool isValidated);

    /// @notice Emitted when the L2 admin is whitelisted or not.
    event AllowL2Admin(address indexed adminAddress);
}
