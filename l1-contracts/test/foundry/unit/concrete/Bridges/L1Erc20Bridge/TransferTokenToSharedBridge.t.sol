// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract TransferTokenToSharedBridgeTest is L1Erc20BridgeTest {
    function test_RevertWhen_SharedBridgeIsNotSender() public {
        address randomSigner = makeAddr("randomSigner");

        vm.prank(randomSigner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, randomSigner));
        bridge.transferTokenToSharedBridge(address(token));
    }

    function test_SuccessfullyTransferTokenToSharedBridge() public {
        token.mint(address(bridge), 1 ether);

        assertEq(token.balanceOf(sharedBridgeAddress), 0);
        assertEq(token.balanceOf(address(bridge)), 1 ether);

        vm.prank(sharedBridgeAddress);
        bridge.transferTokenToSharedBridge(address(token));

        assertEq(token.balanceOf(sharedBridgeAddress), 1 ether);
        assertEq(token.balanceOf(address(bridge)), 0);
    }
}
