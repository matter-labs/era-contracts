// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PrividiumTransactionFilterer} from "contracts/transactionFilterer/PrividiumTransactionFilterer.sol";

contract PrividiumTransactionFiltererTest is MigrationTestBase {
    PrividiumTransactionFilterer internal transactionFiltererProxy;
    PrividiumTransactionFilterer internal transactionFiltererImplementation;
    address internal owner;
    address internal admin;
    address internal sender;
    address internal assetRouter;

    function setUp() public virtual override {
        _deployIntegrationBase();

        owner = makeAddr("owner");
        admin = makeAddr("admin");
        sender = makeAddr("sender");
        // Use real assetRouter from integration deployment
        assetRouter = address(addresses.sharedBridge);

        transactionFiltererImplementation = new PrividiumTransactionFilterer(assetRouter);

        transactionFiltererProxy = PrividiumTransactionFilterer(
            address(
                new TransparentUpgradeableProxy(
                    address(transactionFiltererImplementation),
                    admin,
                    abi.encodeCall(PrividiumTransactionFilterer.initialize, owner)
                )
            )
        );

        vm.prank(owner);
        transactionFiltererProxy.setDepositsAllowed(true);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
