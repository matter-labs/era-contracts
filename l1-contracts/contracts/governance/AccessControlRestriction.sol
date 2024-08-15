// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/AccessControlDefaultAdminRules.sol";
import {IChainAdmin} from "./IChainAdmin.sol";
import {IRestriction} from "./IRestriction.sol";
import { Call } from "./Common.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The Restriction that is designed to provide the access control logic for the `ChainAdmin` contract.
/// @dev It inherits from `AccessControlDefaultAdminRules` without overriding `_setRoleAdmin` functionaity. In other
/// words, the `DEFAULT_ADMIN_ROLE` is the only role that can manage roles. This is done for simplicity.
/// @dev An instance of this restriction should be deployed separately for each `ChainAdmin` contract.
contract AccessControlRestriction is IRestriction, AccessControlDefaultAdminRules {
    /// @notice Required roles to call a specific functions.
    /// @dev Note, that the role 0 means the `DEFAULT_ADMIN_ROLE` from the `AccessControlDefaultAdminRules` contract.
    mapping(address target => mapping(bytes4 selector => bytes32 requiredRole)) public requiredRoles;

    /// @notice Required roles to call a fallback function.
    mapping(address target => bytes32 requiredRole) public requiredRolesForFallback;

    constructor(uint48 initialDelay, address initialDefaultAdmin) AccessControlDefaultAdminRules(initialDelay, initialDefaultAdmin) {}

    /// @notice Sets the required role for a specific function call.
    /// @param _target The address of the contract.
    /// @param _selector The selector of the function.
    /// @param _requiredRole The required role.
    function setRequiredRoleForCall(address _target, bytes4 _selector, bytes32 _requiredRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requiredRoles[_target][_selector] = _requiredRole;
    }

    /// @notice Sets the required role for a fallback function call.
    /// @param _target The address of the contract.
    /// @param _requiredRole The required role.
    function setRequiredRoleForFallback(address _target, bytes32 _requiredRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requiredRolesForFallback[_target] = _requiredRole;
    }

    /// @inheritdoc IRestriction
    function validateCall(
        Call calldata _call, 
        address _invoker
    ) external view {
        // It is very rare that an admin needs to send value somewhere, so we require the invoker to have the DEFAULT_ADMIN_ROLE
        if (_call.value != 0) {
            require(hasRole(DEFAULT_ADMIN_ROLE, _invoker), "AccessControlRestriction: Access denied");
        }

        if (_call.data.length < 4) {
            require(hasRole(requiredRolesForFallback[_call.target], _invoker), "AccessControlRestriction: Fallback function is not allowed");
        } else {
            bytes4 selector = bytes4(_call.data[:4]);
            require(hasRole(requiredRoles[_call.target][selector], _invoker), "AccessControlRestriction: Access denied");
        }
    }
}