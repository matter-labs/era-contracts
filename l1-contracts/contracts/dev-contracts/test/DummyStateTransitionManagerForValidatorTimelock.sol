// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @title DummyStateTransitionManagerForValidatorTimelock
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyStateTransitionManagerForValidatorTimelock {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    address public chainAdmin;
    address public stateTransitionChain;

    constructor(address _chainAdmin, address _stateTransition) {
        chainAdmin = _chainAdmin;
        stateTransitionChain = _stateTransition;
    }

    function getChainAdmin(uint256) external view returns (address) {
        return chainAdmin;
    }

    function stateTransition(uint256) external view returns (address) {
        return stateTransitionChain;
    }
}
