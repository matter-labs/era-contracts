// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";

contract GatewayTransactionFiltererTest is Test {
    GatewayTransactionFilterer internal transactionFiltererProxy;
    GatewayTransactionFilterer internal transactionFiltererImplementation;
    address internal constant owner = address(0x1010101);
    address internal constant admin = address(0x2020202);
    address internal constant sender = address(0x3030303);
    address internal constant bridgehub = address(0x5050505);
    address internal constant assetRouter = address(0x4040404);

    constructor() {
        transactionFiltererImplementation = new GatewayTransactionFilterer(IBridgehub(bridgehub), assetRouter);

        transactionFiltererProxy = GatewayTransactionFilterer(
            address(
                new TransparentUpgradeableProxy(
                    address(transactionFiltererImplementation),
                    admin,
                    abi.encodeCall(GatewayTransactionFilterer.initialize, owner)
                )
            )
        );
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
