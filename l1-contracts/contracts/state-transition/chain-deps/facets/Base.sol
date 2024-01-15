// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../ZkSyncStateTransitionStorage.sol";
import "../../../common/ReentrancyGuard.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZkSyncStateTransitionBase is ReentrancyGuard {
    ZkSyncStateTransitionStorage internal s;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == s.governor, "StateTransition Chain: not governor");
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

    modifier onlyGovernorOrStateTransitionManager() {
        require(
            msg.sender == s.governor || msg.sender == s.stateTransitionManager,
            "StateTransition Chain: Only by governor or state transition manager"
        );
        _;
    }

    /// @notice Checks that the message sender is an active governor or admin
    modifier onlyGovernorOrAdmin() {
        require(msg.sender == s.governor || msg.sender == s.admin, "StateTransition chain: Only by governor or admin");
        _;
    }
}
