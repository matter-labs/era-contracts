// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ILegacyGetters} from "contracts/state-transition/chain-interfaces/ILegacyGetters.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";

/// @notice In integration context, gettersFacetWrapper is backed by UtilsFacet on the
/// deployed chain. The individual test files call gettersFacetWrapper.util_set*() then
/// gettersFacet.getXxx(). Both resolve through the same diamond proxy.
contract GettersFacetTest is MigrationTestBase {
    IGetters internal gettersFacet;
    UtilsFacet internal gettersFacetWrapper;
    ILegacyGetters internal legacyGettersFacet;

    function setUp() public virtual override {
        super.setUp();
        gettersFacet = IGetters(chainAddress);
        gettersFacetWrapper = UtilsFacet(chainAddress);
        legacyGettersFacet = ILegacyGetters(chainAddress);
    }

    // add this to be excluded from coverage report
    function testA() internal virtual {}
}
