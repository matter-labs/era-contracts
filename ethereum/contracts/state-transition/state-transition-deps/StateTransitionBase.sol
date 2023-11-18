// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./StateTransitionStorage.sol";
import "../../common/ReentrancyGuard.sol";
import "../../common/AllowListed.sol";
import "../chain-interfaces/IStateTransitionChain.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
contract StateTransitionBase is ReentrancyGuard, AllowListed {
    StateTransitionStorage internal stateTransitionStorage;

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == stateTransitionStorage.governor, "1g"); // only by governor
        _;
    }

    modifier onlyBridgehub() {
        require(msg.sender == stateTransitionStorage.bridgehub, "1i"); // message not sent by bridgehub
        _;
    }

    modifier onlyChain(uint256 _chainId) {
        require(stateTransitionStorage.stateTransitionChainContract[_chainId] == msg.sender, "1j"); // wrong chainId
        _;
    }

    modifier onlyChainGovernor(uint256 _chainId) {
        require(
            IStateTransitionChain(stateTransitionStorage.stateTransitionChainContract[_chainId]).getGovernor() ==
                msg.sender,
            "1j"
        ); // wrong chainId
        _;
    }
}
