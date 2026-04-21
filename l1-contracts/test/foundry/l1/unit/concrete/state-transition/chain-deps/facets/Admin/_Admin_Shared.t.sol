// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

contract AdminTest is MigrationTestBase {
    IAdmin internal adminFacet;
    address internal testnetVerifier;

    function setUp() public virtual override {
        _deployIntegrationBase();
        adminFacet = IAdmin(chainAddress);
        testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    }

    // add this to be excluded from coverage report
    function testAdminShared() internal virtual {}
}
