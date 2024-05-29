// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Bridgehub} from "../../bridgehub/Bridgehub.sol";

/// @title DummyBridgehub
/// @notice A test smart contract that allows to set State Transition Manager for a given chain
contract DummyBridgehub is Bridgehub {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    constructor() Bridgehub() {}

    function setStateTransitionManager(uint256 _chainId, address _stm) external {
        stateTransitionManager[_chainId] = _stm;
    }
}
