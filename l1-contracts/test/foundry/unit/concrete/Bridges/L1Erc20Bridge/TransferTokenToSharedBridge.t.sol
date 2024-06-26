// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";

contract TransferTokenTest is L1Erc20BridgeTest {
    event DepositInitiated(
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address indexed to,
        address l1Token,
        uint256 amount
    );

    function test_RevertWhen_senderIsNotSharedBridge() public {
        vm.expectRevert("Not shared bridge");
        bridge.transferTokenToSharedBridge(address(0));
    }

    function test_transferTokenToSharedBridgeSuccessfully() public {
        uint256 amount = 0;
        vm.prank(address(dummySharedBridge));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(bridge), address(dummySharedBridge), amount);
        bridge.transferTokenToSharedBridge(address(token));
    }
}
