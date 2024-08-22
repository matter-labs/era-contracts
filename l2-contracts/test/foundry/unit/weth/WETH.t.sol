// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {Script, console2 as console} from "forge-std/Script.sol";

import {Test} from "forge-std/Test.sol";

import { L2WrappedBaseToken } from "contracts/bridge/L2WrappedBaseToken.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

contract WethTest is Test {
    L2WrappedBaseToken internal weth;

    // The owner of the proxy
    address ownerWallet = address(2);

    function setUp() public {
        ownerWallet = makeAddr("owner");
        L2WrappedBaseToken impl = new L2WrappedBaseToken();

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), ownerWallet, "");

        weth = L2WrappedBaseToken(payable(proxy));
    }

    function test_shouldDepositWethByCallingDeposit() public {
        uint256 amount = 100;
        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(address(this)), amount);
    }

    function test_shouldDepositWethBySendingEth() public {
        uint256 amount = 100;
        address(weth).call{value: amount}("");
        assertEq(weth.balanceOf(address(this)), amount);
    }

    function test_revertWhenDepositingWithRandomCalldata() public {
        (bool success, ) = address(weth).call{value: 100}(hex"00000000");
        assertEq(success, false);
    }

    function test_shouldWithdrawWethToL2Eth() public {
        address sender = makeAddr("sender");
        uint256 amount = 100;
        
        vm.deal(sender, amount);


        vm.prank(sender);
        weth.deposit{value: amount}();

        vm.prank(sender);
        weth.withdraw(amount);

        assertEq(weth.balanceOf(sender), 0);
        assertEq(address(sender).balance, amount);
    }

    function test_shouldDepositWethToAnotherAccount() public {
        address sender = makeAddr("sender");
        address receiver = makeAddr("receiver");

        uint256 amount = 100;

        vm.deal(sender, amount);

        vm.prank(sender);
        weth.depositTo{value: amount}(receiver);

        assertEq(weth.balanceOf(receiver), amount);
        assertEq(weth.balanceOf(sender), 0);
    }

    function test_shouldWithdrawWethToAnotherAccount() public {
        address sender = makeAddr("sender");
        address receiver = makeAddr("receiver");

        uint256 amount = 100;

        vm.deal(sender, amount);

        vm.prank(sender);
        weth.deposit{value: amount}();

        vm.prank(sender);
        weth.withdrawTo(receiver, amount);

        assertEq(receiver.balance, amount);
        assertEq(sender.balance, 0);
    }

    function test_revertWhenWithdrawingMoreThanBalance() public {
        vm.expectRevert();
        weth.withdraw(1);
    }

    // function test_revertWhenCallingBridgeMint() public {
    //     weth.bridge
    // }

    // function test_revertWhenCallingBridgeBurn() public {

    // }
}

