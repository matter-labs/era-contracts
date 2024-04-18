// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainStorage} from "../ZkSyncHyperchainStorage.sol";
import {ReentrancyGuard} from "../../../common/ReentrancyGuard.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZkSyncHyperchainBase is ReentrancyGuard {
    // slither-disable-next-line uninitialized-state
    ZkSyncHyperchainStorage internal s;

    /// @notice Checks that the message sender is an active admin
    modifier onlyAdmin() {
        require(msg.sender == s.admin, "Hyperchain: not admin");
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        require(s.validators[msg.sender], "Hyperchain: not validator");
        _;
    }

    modifier onlyStateTransitionManager() {
        require(msg.sender == s.stateTransitionManager, "Hyperchain: not state transition manager");
        _;
    }

    modifier onlyBridgehub() {
        require(msg.sender == s.bridgehub, "Hyperchain: not bridgehub");
        _;
    }

    modifier onlyAdminOrStateTransitionManager() {
        require(
            msg.sender == s.admin || msg.sender == s.stateTransitionManager,
            "Hyperchain: Only by admin or state transition manager"
        );
        _;
    }

    modifier onlyValidatorOrStateTransitionManager() {
        require(
            s.validators[msg.sender] || msg.sender == s.stateTransitionManager,
            "Hyperchain: Only by validator or state transition manager"
        );
        _;
    }

    modifier onlyBaseTokenBridge() {
        require(msg.sender == s.baseTokenBridge, "Hyperchain: Only base token bridge can call this function");
        _;
    }
}
