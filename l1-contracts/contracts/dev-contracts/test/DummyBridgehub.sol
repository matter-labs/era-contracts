// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Bridgehub} from "../../bridgehub/Bridgehub.sol";

/// @title DummyBridgehub
/// @notice A test smart contract which allows to set statetransition manager for given chain
contract DummyBridgehub is Bridgehub {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    /// @notice Constructor
    constructor() Bridgehub() {}

    function setStateTransitionManager(uint256 _chainId, address _stm) external {
        stateTransitionManager[_chainId] = _stm;
    }
}
