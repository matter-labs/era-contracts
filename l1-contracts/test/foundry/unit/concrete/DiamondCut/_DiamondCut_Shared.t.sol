// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {DiamondCutTestContract} from "solpp/dev-contracts/test/DiamondCutTestContract.sol";
import {GettersFacet} from "solpp/state-transition/chain-deps/facets/Getters.sol";

contract DiamondCutTest is Test {
    DiamondCutTestContract internal diamondCutTestContract;
    GettersFacet internal gettersFacet;
}
