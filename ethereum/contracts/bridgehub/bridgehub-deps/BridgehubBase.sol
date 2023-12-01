// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./BridgehubStorage.sol";
import "../../common/ReentrancyGuard.sol";
import "../../common/AllowListed.sol";
import "../../state-transition/state-transition-interfaces/IStateTransition.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract BridgehubBase is ReentrancyGuard, AllowListed {
    BridgehubStorage internal bridgehubStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == bridgehubStorage.governor, "Bridgehub: not governor"); // only by governor
        _;
    }

    modifier onlyStateTransition(uint256 _chainId) {
        require(msg.sender == bridgehubStorage.stateTransition[_chainId], "Bridgehub: not state transition");
        _;
    }

    modifier onlyStateTransitionChain(uint256 _chainId) {
        require(msg.sender == IStateTransition(bridgehubStorage.stateTransition[_chainId]).getStateTransitionChain(_chainId), "Bridgehub: not state transition chain");
        _;
    }
}
