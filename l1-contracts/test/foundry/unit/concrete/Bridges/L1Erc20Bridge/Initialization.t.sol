// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";

contract InitializationTest is L1Erc20BridgeTest {
    function test_RevertWhen_DoubleInitialization() public {
        vm.expectRevert(bytes("1B"));
        bridge.initialize();
    }
}
