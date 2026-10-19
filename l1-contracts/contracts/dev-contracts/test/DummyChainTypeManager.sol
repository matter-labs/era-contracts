// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {ChainTypeManager} from "../../state-transition/ChainTypeManager.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyChainTypeManager is ChainTypeManager {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    address internal zkChain;

    /// @notice Constructor
    /// @dev The permissionless validator is a non-zero placeholder, which an L1 CTM requires.
    constructor() ChainTypeManager(address(0), address(0), address(0), address(this), address(0)) {}

    function setZKChain(address _zkChain) external {
        zkChain = _zkChain;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
