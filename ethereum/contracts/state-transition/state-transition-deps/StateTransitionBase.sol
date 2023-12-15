// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./StateTransitionStorage.sol";
import "../../common/ReentrancyGuard.sol";
import "../chain-interfaces/IStateTransitionChain.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract ZkSyncStateTransitionBase is ReentrancyGuard {
    StateTransitionStorage internal stateTransitionStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == stateTransitionStorage.governor, "StateTransition: only governor");
        _;
    }

    modifier onlyBridgehub() {
        require(msg.sender == stateTransitionStorage.bridgehub, "StateTransition: only bridgehub");
        _;
    }

    modifier onlyChain(uint256 _chainId) {
        require(
            stateTransitionStorage.stateTransitionChainContract[_chainId] == msg.sender,
            "StateTransition: only chain"
        );
        _;
    }

    modifier onlyChainGovernor(uint256 _chainId) {
        require(
            IStateTransitionChain(stateTransitionStorage.stateTransitionChainContract[_chainId]).getGovernor() ==
                msg.sender,
            "StateTransition: only chain governor"
        );
        _;
    }
}
