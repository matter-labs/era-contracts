// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../StateTransitionChainStorage.sol";
import "../../../common/ReentrancyGuard.sol";
import "../../../common/AllowListed.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract StateTransitionChainBase is ReentrancyGuard, AllowListed {
    StateTransitionChainStorage internal chainStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == chainStorage.governor, "PCBase 1"); // only by governor
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        require(chainStorage.validators[msg.sender], "PCBase 2"); // validator is not active
        _;
    }

    modifier onlyStateTransition() {
        require(msg.sender == chainStorage.stateTransition, "PCBase 3"); // message not sent by state transition
        _;
    }

    modifier onlyBridgehub() {
        require(msg.sender == chainStorage.bridgehub, "PCBase 4"); // message not sent by bridgehub
        _;
    }

    modifier onlyGovernorOrStateTransition() {
        require(
            msg.sender == chainStorage.governor || msg.sender == chainStorage.stateTransition,
            "Only by governor or proof system"
        );
        _;
    }

    /// @notice Checks that the message sender is an active governor or admin
    modifier onlyGovernorOrAdmin() {
        require(msg.sender == chainStorage.governor || msg.sender == chainStorage.admin, "Only by governor or admin");
        _;
    }
}
