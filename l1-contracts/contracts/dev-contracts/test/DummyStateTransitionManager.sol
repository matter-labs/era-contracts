// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/StateTransitionManager.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyStateTransitionManager is StateTransitionManager {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    /// @notice Constructor
    constructor() StateTransitionManager(address(0)) {}

    function setStateTransition(uint256 _chainId, address _stateTransition) external {
        stateTransition[_chainId] = _stateTransition;
    }
}
