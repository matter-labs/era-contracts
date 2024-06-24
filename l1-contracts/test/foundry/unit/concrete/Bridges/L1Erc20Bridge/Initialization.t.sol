// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";

contract InitializationTest is L1Erc20BridgeTest {
    function test_RevertWhen_DoubleInitialization() public {
        L1ERC20Bridge bridge = new L1ERC20Bridge(IL1SharedBridge(address(dummySharedBridge)));

        vm.expectRevert(bytes("1B"));
        bridge.initialize();
    }
}
