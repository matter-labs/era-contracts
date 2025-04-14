// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title AccessControlRestriction contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAccessControlRestriction {
    /// @notice Emitted when the required role for a specific function is set.
    event RoleSet(address indexed target, bytes4 indexed selector, bytes32 requiredRole);

    /// @notice Emitted when the required role for a fallback function is set.
    event FallbackRoleSet(address indexed target, bytes32 requiredRole);
}
