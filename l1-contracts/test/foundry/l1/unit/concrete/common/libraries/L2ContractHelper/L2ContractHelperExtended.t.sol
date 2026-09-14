// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

contract L2ContractHelperExtendedTest is Test {
    function test_computeCreateAddress_matchesEvmCreateRlpBoundaries() public pure {
        address sender = 0xdEADBEeF00000000000000000000000000000000;

        assertEq(L2ContractHelper.computeCreateAddress(sender, 0), 0xf2048C36a5536FeA3Bc71d49ed59f2c65C546EEA);
        assertEq(L2ContractHelper.computeCreateAddress(sender, 1), 0x054DD934335eA61232Ae4C051f8bF20e540f8291);
        assertEq(L2ContractHelper.computeCreateAddress(sender, 0x7f), 0x7FEb088E1893d4a1087288D386c07252ABB3c02e);
        assertEq(L2ContractHelper.computeCreateAddress(sender, 0x80), 0x2297787B25B800d655071345A1D3a7951404B50C);
        assertEq(L2ContractHelper.computeCreateAddress(sender, 0xff), 0xC8d17a8BDB6001525F8594E3cA4413D4BD644605);
        assertEq(L2ContractHelper.computeCreateAddress(sender, 0x100), 0xA0dDf5980551B5eC83721BCF168785Ac3CeDB183);
        assertEq(L2ContractHelper.computeCreateAddress(sender, 0xffff), 0xE23074ddC86CFc8B145359AB5BA3f10a2c7Df3Dd);
        assertEq(L2ContractHelper.computeCreateAddress(sender, 0x10000), 0x57E44db246f8C377C7923969B4067223dE875B1C);
        assertEq(L2ContractHelper.computeCreateAddress(sender, 1 << 48), 0x4917b2b032e5911c46cC8118e193DecF40303F41);
        assertEq(
            L2ContractHelper.computeCreateAddress(sender, type(uint256).max),
            0xCCC3628fF8Af383753A6446481Dc7c82C760dcFf
        );
        assertEq(L2ContractHelper.computeCreateAddress(address(0), 0), 0xBd770416a3345F91E4B34576cb804a576fa48EB1);
    }
}
