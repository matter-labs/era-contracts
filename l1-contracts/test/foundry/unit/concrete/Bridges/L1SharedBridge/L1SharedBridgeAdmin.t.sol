// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1SharedBridgeTest} from "./_L1SharedBridge_Shared.t.sol";

/// We are testing all the specified revert and require cases.
contract L1SharedBridgeAdminTest is L1SharedBridgeTest {
    uint256 internal randomChainId = 123456;

    function testAdminCanInitializeChainGovernance() public {
        address randomL2Bridge = makeAddr("randomL2Bridge");

        vm.prank(admin);
        sharedBridge.initializeChainGovernance(randomChainId, randomL2Bridge);

        assertEq(sharedBridge.l2BridgeAddress(randomChainId), randomL2Bridge);
    }

    function testAdminCanNotReinitializeChainGovernance() public {
        address randomNewBridge = makeAddr("randomNewBridge");

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(admin);
        sharedBridge.reinitializeChainGovernance(randomChainId, randomNewBridge);
    }
}
