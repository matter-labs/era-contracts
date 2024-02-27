// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {RegistryTest} from "./_Registry_Shared.t.sol";

contract NewStateTransitionTest is RegistryTest {
    function setUp() public {
        stateTransitionAddress = makeAddr("stateTransitionAddress");
    }

    // add this to be excluded from coverage report
    function test() internal override {}

    // function test_RevertWhen_NonGovernor() public {
    //     vm.prank(NON_GOVERNOR);
    //     vm.expectRevert(bytes.concat("12g"));
    //     bridgehub.addStateTransition(stateTransitionAddress);
    // }

    // function test_RevertWhen_StateTransitionAlreadyExists() public {
    //     vm.prank(GOVERNOR);
    //     bridgehub.addStateTransition(stateTransitionAddress);

    //     vm.prank(GOVERNOR);
    //     vm.expectRevert(bytes.concat("r35"));
    //     bridgehub.addStateTransition(stateTransitionAddress);
    // }

    // function test_NewStateTransitionSuccessful() public {
    //     vm.prank(GOVERNOR);
    //     bridgehub.addStateTransition(stateTransitionAddress);

    //     assertEq(bridgehub.getIsStateTransition(stateTransitionAddress), true, "should be true");
    //     assertEq(bridgehub.getTotaStateTransitions(), 1, "should be exactly 1 proof system");
    // }
}
