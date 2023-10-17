// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./BridgehubStorage.sol";
import "../../common/ReentrancyGuard.sol";
import "../../common/AllowListed.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract BridgehubBase is ReentrancyGuard, AllowListed {
    BridgehubStorage internal bridgehubStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == bridgehubStorage.governor, "12g"); // only by governor
        _;
    }

    modifier onlyStateTransition(uint256 _chainId) {
        require(msg.sender == bridgehubStorage.stateTransition[_chainId], "12c");
        _;
    }

    modifier onlyStateTransitionChain(uint256 _chainId) {
        require(msg.sender == bridgehubStorage.proofChain[_chainId], "12e");
        _;
    }

    /// @notice Checks that the message sender is an active governor or admin
    modifier onlyGovernorOrAdmin() {
        require(
            msg.sender == bridgehubStorage.governor || msg.sender == bridgehubStorage.admin,
            "Only by governor or admin"
        );
        _;
    }
}
