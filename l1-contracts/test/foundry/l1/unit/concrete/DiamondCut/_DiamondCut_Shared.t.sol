// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UtilsTest} from "foundry-test/l1/unit/concrete/Utils/Utils.t.sol";
import {DiamondCutTestContract} from "contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

contract DiamondCutTest is UtilsTest {
    DiamondCutTestContract internal diamondCutTestContract;
    GettersFacet internal gettersFacet;
}
