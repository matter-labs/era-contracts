// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DiamondCutTestContract} from "contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

contract DiamondCutTest is Test {
    DiamondCutTestContract internal diamondCutTestContract;
    GettersFacet internal gettersFacet;
}
