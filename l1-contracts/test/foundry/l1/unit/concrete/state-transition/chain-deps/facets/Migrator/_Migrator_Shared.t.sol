// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";

import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

contract MigratorTest is MigrationTestBase {
    IMigrator internal migratorFacet;
    IGetters internal gettersFacet;
    DummyBridgehub internal dummyBridgehub;
    address internal testnetVerifier;

    function setUp() public virtual override {
        _deployIntegrationBase();
        migratorFacet = IMigrator(chainAddress);
        gettersFacet = IGetters(chainAddress);
        // Point dummyBridgehub to the real bridgehub address so mockCall targets work correctly.
        dummyBridgehub = DummyBridgehub(address(addresses.bridgehub));
        testnetVerifier = makeAddr("testnetVerifier");
    }

    // add this to be excluded from coverage report
    function testMigratorShared() internal virtual {}
}
