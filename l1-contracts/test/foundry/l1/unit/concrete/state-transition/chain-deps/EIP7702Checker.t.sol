// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {EIP7702Checker} from "contracts/state-transition/chain-deps/EIP7702Checker.sol";

contract EIP7702CheckerTest is Test {
    EIP7702Checker internal checker;
    address internal account = makeAddr("account");

    function setUp() public {
        checker = new EIP7702Checker();
    }

    function test_isEIP7702Account_Delegated() public {
        vm.etch(account, abi.encodePacked(hex"ef0100", makeAddr("delegate")));
        assertTrue(checker.isEIP7702Account(account));
    }

    function test_isEIP7702Account_SignAndAttachDelegation() public {
        Vm.Wallet memory wallet = vm.createWallet("eoa");
        vm.signAndAttachDelegation(address(checker), wallet.privateKey);
        assertTrue(checker.isEIP7702Account(wallet.addr));
    }

    function test_isEIP7702Account_FalseForEOA() public view {
        assertFalse(checker.isEIP7702Account(account));
    }

    function test_isEIP7702Account_FalseForContract() public view {
        assertFalse(checker.isEIP7702Account(address(checker)));
    }

    function test_isEIP7702Account_FalseForWrongPrefix() public {
        vm.etch(account, abi.encodePacked(hex"ef0200", makeAddr("delegate")));
        assertFalse(checker.isEIP7702Account(account));
    }
}
