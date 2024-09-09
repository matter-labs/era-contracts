// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {TransactionFilterer} from "contracts/transactionFilterer/TransactionFilterer.sol";

contract TransactionFiltererTest is Test {
    TransactionFilterer internal transactionFiltererProxy;
    TransactionFilterer internal transactionFiltererImplementation;
    address internal constant owner = address(0x1010101);
    address internal constant admin = address(0x2020202);
    address internal constant sender = address(0x3030303);

    constructor() {
        transactionFiltererImplementation = new TransactionFilterer();

        transactionFiltererProxy = TransactionFilterer(
            address(
                new TransparentUpgradeableProxy(
                    address(transactionFiltererImplementation),
                    admin,
                    abi.encodeCall(TransactionFilterer.initialize, owner)
                )
            )
        );
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
