// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {AddressAliasHelperTest} from "contracts/dev-contracts/test/AddressAliasHelperTest.sol";

contract AddressAliasHelperSharedTest is MigrationTestBase {
    AddressAliasHelperTest addressAliasHelper;

    function setUp() public override {
        super.setUp();
        addressAliasHelper = new AddressAliasHelperTest();
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
