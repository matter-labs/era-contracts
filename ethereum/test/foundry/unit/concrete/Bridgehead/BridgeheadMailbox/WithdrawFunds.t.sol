// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgeheadMailboxTest} from "./_BridgeheadMailbox_Shared.t.sol";

/* solhint-enable max-line-length */

contract WithdrawFundsTest is BridgeheadMailboxTest {
    address internal to;
    uint256 internal amount;

    function setUp() public {
        to = makeAddr("to");
        amount = 123456789;
    }

    function test_RevertWhen_CalledByNonChainContract() public {
        address nonChainContract = makeAddr("nonChainContract");

        vm.expectRevert(abi.encodePacked("12c"));
        vm.startPrank(nonChainContract);
        bridgehead.withdrawFunds(chainId, to, amount);
    }

    function test_RevertWhen_NotEnoughBalance() public {
        address chainContract = bridgehead.getChainContract(chainId);

        // setting the balance of the bridgehead to 0 and trying to withdraw 1 ether
        vm.deal(chainContract, 0 ether);
        amount = 1 ether;

        vm.expectRevert(abi.encodePacked("pz"));
        vm.startPrank(chainContract);
        bridgehead.withdrawFunds(chainId, to, amount);
    }

    function test_SuccessfulWithdraw() public {
        address chainContract = bridgehead.getChainContract(chainId);

        vm.deal(address(bridgehead), 100 ether);
        amount = 10 ether;

        vm.startPrank(chainContract);
        bridgehead.withdrawFunds(chainId, to, amount);
    }
}
