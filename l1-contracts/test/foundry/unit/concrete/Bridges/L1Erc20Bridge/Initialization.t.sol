// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {SlotOccupied} from "contracts/common/L1ContractErrors.sol";

contract InitializationTest is L1Erc20BridgeTest {
    function test_RevertWhen_DoubleInitialization() public {
        vm.expectRevert(SlotOccupied.selector);
        bridge.initialize();
    }
}
