// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PrividiumTransactionFilterer} from "contracts/transactionFilterer/PrividiumTransactionFilterer.sol";

contract PrividiumTransactionFiltererTest is MigrationTestBase {
    PrividiumTransactionFilterer internal transactionFiltererProxy;
    PrividiumTransactionFilterer internal transactionFiltererImplementation;
    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal sender = makeAddr("sender");
    address internal assetRouter = makeAddr("assetRouter");

    constructor() {
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
