// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

contract AdminTest is MigrationTestBase {
    IAdmin internal adminFacet;
    // Kept for backward-compatibility with tests that prank as bridgehub to call UtilsFacet setters,
    // or that override setUp() and build their own diamond from scratch.
    DummyBridgehub internal dummyBridgehub;
    address internal testnetVerifier;

    function setUp() public virtual override {
        super.setUp();
        adminFacet = IAdmin(chainAddress);
        // Create a standalone DummyBridgehub for tests that need to prank as it.
        // It is not wired into the integration deployment; its address is only used for prank targets.
        dummyBridgehub = new DummyBridgehub();
        testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    }

    // add this to be excluded from coverage report
    function testAdminShared() internal virtual {}
}
