// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";

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
