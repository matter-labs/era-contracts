// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {L1ContractDeployer} from "foundry-test/l1/integration/_SharedL1ContractDeployer.t.sol";
import {DiamondCutTestContract} from "contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

contract DiamondCutTest is MigrationTestBase {
    DiamondCutTestContract internal diamondCutTestContract;
    GettersFacet internal gettersFacet;
}
