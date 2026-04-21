// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";

contract GatewayTransactionFiltererTest is MigrationTestBase {
    GatewayTransactionFilterer internal transactionFiltererProxy;
    GatewayTransactionFilterer internal transactionFiltererImplementation;
    address internal owner;
    address internal admin;
    address internal sender;
    address internal bridgehub;
    address internal assetRouter;

    function setUp() public virtual override {
        _deployIntegrationBase();

        owner = makeAddr("owner");
        admin = makeAddr("admin");
        sender = makeAddr("sender");
        // Use real bridgehub and assetRouter from integration deployment
        bridgehub = address(addresses.bridgehub);
        assetRouter = address(addresses.sharedBridge);

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
    function test() internal virtual override {}
}
