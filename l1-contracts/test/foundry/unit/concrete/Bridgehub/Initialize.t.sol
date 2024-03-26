// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubTest} from "./_Bridgehub_Shared.t.sol";

import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";

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
}
