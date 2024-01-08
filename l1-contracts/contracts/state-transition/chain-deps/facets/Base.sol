// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../StateTransitionChainStorage.sol";
import "../../../common/ReentrancyGuard.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract StateTransitionChainBase is ReentrancyGuard {
    StateTransitionChainStorage internal chainStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == chainStorage.governor, "StateTransition Chain: not governor");
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        require(chainStorage.validators[msg.sender], "StateTransition Chain: not validator");
        _;
    }

    modifier onlyStateTransition() {
        require(msg.sender == chainStorage.stateTransition, "StateTransition Chain: not state transition");
        _;
    }

    modifier onlyBridgehub() {
        require(msg.sender == chainStorage.bridgehub, "StateTransition Chain: not bridgehub");
        _;
    }

    modifier onlyGovernorOrStateTransition() {
        require(
            msg.sender == chainStorage.governor || msg.sender == chainStorage.stateTransition,
            "StateTransition Chain: Only by governor or state transition"
        );
        _;
    }

    /// @notice Checks that the message sender is an active governor or admin
    modifier onlyGovernorOrAdmin() {
        require(
            msg.sender == chainStorage.governor || msg.sender == chainStorage.admin,
            "StateTransition chain: Only by governor or admin"
        );
        _;
    }
}
