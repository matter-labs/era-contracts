// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyStateTransitionManagerForValidatorTimelock  {
        /// @notice Constructor

        address public chainAdmin;
        address public stateTransitionChain;

        constructor(address _chainAdmin, address _stateTransition) {
            chainAdmin = _chainAdmin;
            stateTransitionChain = _stateTransition;
        }

        function getChainAdmin(uint256 ) external returns (address){
            return chainAdmin;
        }

        function stateTransition(uint256 ) external returns (address){
            return stateTransitionChain;
        }

}
