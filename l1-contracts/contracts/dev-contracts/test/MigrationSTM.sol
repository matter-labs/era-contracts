// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract MigrationSTM {

    // add this to be excluded from coverage report
    function test() internal virtual {}
    
    address public chainAdmin;

    /// @notice Constructor
    constructor(address _chainAdmin)  {
        chainAdmin = _chainAdmin;
    }

    function setChainAdmin(address _chainAdmin) external {
        chainAdmin = _chainAdmin;
    }

    function getChainAdmin(uint256) external view returns(address) {
        return chainAdmin;
    }
}
