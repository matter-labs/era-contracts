// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainStorage} from "../ZkSyncHyperchainStorage.sol";
import {ReentrancyGuard} from "../../../common/ReentrancyGuard.sol";

import {Unauthorized} from "../../../common/L1ContractErrors.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZkSyncHyperchainBase is ReentrancyGuard {
    // slither-disable-next-line uninitialized-state
    ZkSyncHyperchainStorage internal s;

    /// @notice Checks that the message sender is an active admin
    modifier onlyAdmin() {
        if (msg.sender != s.admin) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        if (!s.validators[msg.sender]) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyStateTransitionManager() {
        if (msg.sender != s.stateTransitionManager) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyBridgehub() {
        if (msg.sender != s.bridgehub) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyAdminOrStateTransitionManager() {
        if (msg.sender != s.admin && msg.sender != s.stateTransitionManager) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyValidatorOrStateTransitionManager() {
        if (!s.validators[msg.sender] && msg.sender != s.stateTransitionManager) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyBaseTokenBridge() {
        if (msg.sender != s.baseTokenBridge) {
            revert Unauthorized(msg.sender);
        }
        _;
    }
}
