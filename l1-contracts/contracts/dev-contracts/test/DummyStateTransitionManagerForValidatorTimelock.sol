// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title DummyStateTransitionManagerForValidatorTimelock
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyStateTransitionManagerForValidatorTimelock {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    address public chainAdmin;
    address public hyperchainAddress;

    constructor(address _chainAdmin, address _hyperchain) {
        chainAdmin = _chainAdmin;
        hyperchainAddress = _hyperchain;
    }

    function getChainAdmin(uint256) external view returns (address) {
        return chainAdmin;
    }

    function getHyperchain(uint256) external view returns (address) {
        return hyperchainAddress;
    }
}
