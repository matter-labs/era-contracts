// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubMailboxTest} from "./_BridgehubMailbox_Shared.t.sol";

contract WithdrawFundsTest is BridgehubMailboxTest {
    // address internal to;
    // uint256 internal amount;
    // function setUp() public {
    //     to = makeAddr("to");
    //     amount = 123456789;
    // }
    // function test_RevertWhen_CalledByNonChainContract() public {
    //     address nonChainContract = makeAddr("nonChainContract");
    //     vm.expectRevert(abi.encodePacked("12c"));
    //     vm.startPrank(nonChainContract);
    //     bridgehub.withdrawFunds(chainId, to, amount);
    // }
    // function test_RevertWhen_NotEnoughBalance() public {
    //     address chainContract = bridgehub.getStateTransition(chainId);
    //     // setting the balance of the bridgehub to 0 and trying to withdraw 1 ether
    //     vm.deal(chainContract, 0 ether);
    //     amount = 1 ether;
    //     vm.expectRevert(abi.encodePacked("pz"));
    //     vm.startPrank(chainContract);
    //     bridgehub.withdrawFunds(chainId, to, amount);
    // }
    // function test_SuccessfulWithdraw() public {
    //     address chainContract = bridgehub.getStateTransition(chainId);
    //     vm.deal(address(bridgehub), 100 ether);
    //     amount = 10 ether;
    //     vm.startPrank(chainContract);
    //     bridgehub.withdrawFunds(chainId, to, amount);
    // }
}
