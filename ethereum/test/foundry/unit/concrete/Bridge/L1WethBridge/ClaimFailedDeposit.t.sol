// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {L1WethBridgeTest} from "./_L1WethBridge_Shared.t.sol";

contract ClaimFailedDepositTest is L1WethBridgeTest {
    function test_RevertWhen_Claiming() public {
        vm.expectRevert("Method not supported. Failed deposit funds are sent to the L2 refund recipient address.");
        bridgeProxy.claimFailedDeposit(address(0), address(0), bytes32(0), 0, 0, 0, new bytes32[](0));
    }
}
