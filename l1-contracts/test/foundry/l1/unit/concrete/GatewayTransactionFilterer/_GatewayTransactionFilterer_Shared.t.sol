// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";

contract GatewayTransactionFiltererTest is Test {
    GatewayTransactionFilterer internal transactionFiltererProxy;
    GatewayTransactionFilterer internal transactionFiltererImplementation;
    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal sender = makeAddr("sender");
    address internal bridgehub = makeAddr("bridgehub");
    address internal assetRouter = makeAddr("assetRouter");

    constructor() {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        sender = makeAddr("sender");
        bridgehub = makeAddr("bridgehub");
        assetRouter = makeAddr("assetRouter");
        transactionFiltererImplementation = new GatewayTransactionFilterer(IBridgehubBase(bridgehub), assetRouter);

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
