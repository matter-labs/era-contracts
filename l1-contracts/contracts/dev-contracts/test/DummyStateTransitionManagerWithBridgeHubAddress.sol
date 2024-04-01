// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/StateTransitionManager.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyStateTransitionManagerWBH is StateTransitionManager {
    /// @notice Constructor
    constructor(address bridgeHub) StateTransitionManager(bridgeHub) {}

    function setHyperchain(uint256 _chainId, address _hyperchain) external {
        hyperchain[_chainId] = _hyperchain;
    }
}
