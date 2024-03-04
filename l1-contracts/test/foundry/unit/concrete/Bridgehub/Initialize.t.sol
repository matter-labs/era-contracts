// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubTest} from "./_Bridgehub_Shared.t.sol";

import {DiamondInit} from "solpp/state-transition/chain-deps/DiamondInit.sol";

contract InitializeTest is BridgehubTest {
    address internal governor;
    address internal chainImplementation;
    address internal chainProxyAdmin;
    uint256 internal priorityTxMaxGasLimit;

    function setUp() public {
        bridgehubDiamondInit = new DiamondInit();

        governor = GOVERNOR;
        chainImplementation = makeAddr("chainImplementation");
        chainProxyAdmin = makeAddr("chainProxyAdmin");
        priorityTxMaxGasLimit = 1090193;
    }

    // add this to be excluded from coverage report
    function test() internal override {}

    // function test_RevertWhen_AlreadyInitialized() public {
    //     bridgehub.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);

    //     vm.expectRevert(bytes.concat("bridgehub1"));
    //     bridgehub.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);
    // }

    // function test_InitializeSuccessfully() public {
    //     bridgehub.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);

    //     assertEq(bridgehub.governor(), governor);
    //     assertEq(bridgehub.getChainImplementation(), chainImplementation);
    //     assertEq(bridgehub.getChainProxyAdmin(), chainProxyAdmin);
    //     assertEq(address(bridgehub.getAllowList()), address(allowList));
    //     assertEq(bridgehub.getPriorityTxMaxGasLimit(), priorityTxMaxGasLimit);
    // }
}
