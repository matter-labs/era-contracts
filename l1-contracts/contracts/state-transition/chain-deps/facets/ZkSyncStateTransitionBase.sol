// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ZkSyncStateTransitionStorage} from "../ZkSyncStateTransitionStorage.sol";
import {ReentrancyGuard} from "../../../common/ReentrancyGuard.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZkSyncStateTransitionBase is ReentrancyGuard {
    ZkSyncStateTransitionStorage internal s;

    /// @notice Checks that the message sender is an active admin
    modifier onlyAdmin() {
        require(msg.sender == s.admin, "StateTransition Chain: not admin");
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        require(s.validators[msg.sender], "StateTransition Chain: not validator");
        _;
    }

    modifier onlyStateTransitionManager() {
        require(msg.sender == s.stateTransitionManager, "StateTransition Chain: not state transition manager");
        _;
    }

    modifier onlyBridgehub() {
        require(msg.sender == s.bridgehub, "StateTransition Chain: not bridgehub");
        _;
    }

    modifier onlyAdminOrStateTransitionManager() {
        require(
            msg.sender == s.admin || msg.sender == s.stateTransitionManager,
            "StateTransition Chain: Only by admin or state transition manager"
        );
        _;
    }

    modifier onlyValidatorOrStateTransitionManager() {
        require(
            s.validators[msg.sender] || msg.sender == s.stateTransitionManager,
            "StateTransition Chain: Only by validator or state transition manager"
        );
        _;
    }

    modifier onlyBaseTokenBridge() {
        require(msg.sender == s.baseTokenBridge, "Only shared bridge can call this function");
        _;
    }
}
