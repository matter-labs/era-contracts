// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {ChainTypeManager} from "../../state-transition/ChainTypeManager.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyChainTypeManagerWBH is ChainTypeManager {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    address hyperchain;
    /// @notice Constructor
    constructor(address bridgeHub) ChainTypeManager(bridgeHub) {}

    function setHyperchain(uint256 _chainId, address _hyperchain) external {
        hyperchain = _hyperchain;
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
