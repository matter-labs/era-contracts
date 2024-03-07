// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetStateTransitionManagerTest is GettersFacetTest {
    function test() public {
        address expected = makeAddr("stateTranstionManager");
        gettersFacetWrapper.util_setStateTransitionManager(expected);

        address received = gettersFacet.getStateTransitionManager();

        assertEq(expected, received, "StateTransitionManager address is incorrect");
    }
}
