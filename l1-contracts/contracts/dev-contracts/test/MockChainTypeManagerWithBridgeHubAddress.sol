// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {ChainTypeManager} from "../../state-transition/ChainTypeManager.sol";

/// @title MockChainTypeManagerWBH
/// @notice A ChainTypeManager over a given Bridgehub, for the Bridgehub unit tests.
contract MockChainTypeManagerWBH is ChainTypeManager {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    address internal zkChain;
    /// @notice Constructor
    /// @dev The permissionless validator is a non-zero placeholder, which an L1 CTM requires.
    constructor(address bridgeHub) ChainTypeManager(bridgeHub, address(0), address(0), address(this), address(0)) {}

    function setZKChain(address _zkChain) external {
        zkChain = _zkChain;
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
