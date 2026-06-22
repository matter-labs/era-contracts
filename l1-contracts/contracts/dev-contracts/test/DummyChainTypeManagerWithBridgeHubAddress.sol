// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {EraChainTypeManager} from "../../state-transition/EraChainTypeManager.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyChainTypeManagerWBH is EraChainTypeManager {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    address zkChain;
    /// @notice Constructor
    constructor(address bridgeHub) EraChainTypeManager(bridgeHub) {}

    function setZKChain(uint256 _chainId, address _zkChain) external {
        zkChain = _zkChain;
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
