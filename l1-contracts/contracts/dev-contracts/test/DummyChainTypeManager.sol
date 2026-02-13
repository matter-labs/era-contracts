// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {EraChainTypeManager} from "../../state-transition/EraChainTypeManager.sol";

/// @title DummyExecutor
/// @notice A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.
contract DummyChainTypeManager is EraChainTypeManager {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    address zkChain;

    /// @notice Constructor
    constructor() EraChainTypeManager(address(0), address(0), address(0), address(0)) {}

    function setZKChain(uint256 _chainId, address _zkChain) external {
        zkChain = _zkChain;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
