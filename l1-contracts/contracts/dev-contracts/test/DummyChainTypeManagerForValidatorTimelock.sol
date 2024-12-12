// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title DummyChainTypeManagerForValidatorTimelock
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyChainTypeManagerForValidatorTimelock {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    address public chainAdmin;
    address public zkChainAddress;

    constructor(address _chainAdmin, address _zkChain) {
        chainAdmin = _chainAdmin;
        zkChainAddress = _zkChain;
    }

    function getChainAdmin(uint256) external view returns (address) {
        return chainAdmin;
    }

    function getZKChain(uint256) external view returns (address) {
        return zkChainAddress;
    }

    function getHyperchain(uint256) external view returns (address) {
        return zkChainAddress;
    }

    function setZKChain(uint256, address _zkChain) external {
        zkChainAddress = _zkChain;
    }
}
