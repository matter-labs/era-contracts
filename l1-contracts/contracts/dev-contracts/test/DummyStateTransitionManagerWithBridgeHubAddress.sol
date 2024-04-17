// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {StateTransitionManager} from "../../state-transition/StateTransitionManager.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyStateTransitionManagerWBH is StateTransitionManager {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice Constructor
    constructor(address bridgeHub) StateTransitionManager(bridgeHub, type(uint256).max) {}

    function setHyperchain(uint256 _chainId, address _hyperchain) external {
        hyperchainMap.set(_chainId, _hyperchain);
    }
}
