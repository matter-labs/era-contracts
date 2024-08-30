// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetStateTransitionManagerTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("stateTransitionManager");
        gettersFacetWrapper.util_setStateTransitionManager(expected);

        address received = gettersFacet.getStateTransitionManager();

        assertEq(expected, received, "StateTransitionManager address is incorrect");
    }
}
