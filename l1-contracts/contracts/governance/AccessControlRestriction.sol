// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AccessToFallbackDenied, AccessToFunctionDenied, ZeroAddress} from "../common/L1ContractErrors.sol";
import {IAccessControlRestriction} from "./IAccessControlRestriction.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts-v4/access/AccessControlDefaultAdminRules.sol";
import {Restriction} from "./restriction/Restriction.sol";
import {Call} from "./Common.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The Restriction that is designed to provide the access control logic for the `ChainAdmin` contract.
/// @dev It inherits from `AccessControlDefaultAdminRules` without overriding `_setRoleAdmin` functionality. In other
/// words, the `DEFAULT_ADMIN_ROLE` is the only role that can manage roles. This is done for simplicity.
/// @dev An instance of this restriction should be deployed separately for each `ChainAdmin` contract.
/// @dev IMPORTANT: this function does not validate the ability of the invoker to use `msg.value`. Thus,
/// either all callers with access to functions should be trusted to not steal ETH from the `ChainAdmin` account
/// or no ETH should be passively stored in `ChainAdmin` account.
contract AccessControlRestriction is Restriction, IAccessControlRestriction, AccessControlDefaultAdminRules {
    /// @notice Required roles to call a specific function.
    /// @dev Note, that the role 0 means the `DEFAULT_ADMIN_ROLE` from the `AccessControlDefaultAdminRules` contract.
    mapping(address target => mapping(bytes4 selector => bytes32 requiredRole)) public requiredRoles;

    /// @notice Required roles to call a fallback function.
    mapping(address target => bytes32 requiredRole) public requiredRolesForFallback;

    constructor(
        uint48 initialDelay,
        address initialDefaultAdmin
    ) AccessControlDefaultAdminRules(initialDelay, initialDefaultAdmin) {}

    /// @notice Sets the required role for a specific function call.
    /// @param _target The address of the contract.
    /// @param _selector The selector of the function.
    /// @param _requiredRole The required role.
    function setRequiredRoleForCall(
        address _target,
        bytes4 _selector,
        bytes32 _requiredRole
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_target == address(0)) {
            revert ZeroAddress();
        }
        requiredRoles[_target][_selector] = _requiredRole;

        emit RoleSet(_target, _selector, _requiredRole);
    }

    /// @notice Sets the required role for a fallback function call.
    /// @param _target The address of the contract.
    /// @param _requiredRole The required role.
    function setRequiredRoleForFallback(address _target, bytes32 _requiredRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_target == address(0)) {
            revert ZeroAddress();
        }
        requiredRolesForFallback[_target] = _requiredRole;

        emit FallbackRoleSet(_target, _requiredRole);
    }

    /// @inheritdoc Restriction
    function validateCall(Call calldata _call, address _invoker) external view override {
        // Note, that since `DEFAULT_ADMIN_ROLE` is 0 and the default storage value for the
        // `requiredRoles` and `requiredRolesForFallback` is 0, the default admin is by default a required
        // role for all the functions.
        if (_call.data.length < 4) {
            // Note, that the following restriction protects only for targets that were compiled after
            // Solidity v0.4.18, since before a substring of selector could still call the function.
            if (!hasRole(requiredRolesForFallback[_call.target], _invoker)) {
                revert AccessToFallbackDenied(_call.target, _invoker);
            }
        } else {
            bytes4 selector = bytes4(_call.data[:4]);
            if (!hasRole(requiredRoles[_call.target][selector], _invoker)) {
                revert AccessToFunctionDenied(_call.target, selector, _invoker);
            }
        }
    }
}
