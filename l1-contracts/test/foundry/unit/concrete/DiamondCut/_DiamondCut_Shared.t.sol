// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// solhint-disable max-line-length

import {Test} from "forge-std/Test.sol";
import {DiamondCutTestContract} from "../../../../../contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {GettersFacet} from "../../../../../contracts/zksync/facets/Getters.sol";

// solhint-enable max-line-length

contract DiamondCutTest is Test {
    DiamondCutTestContract internal diamondCutTestContract;
    GettersFacet internal gettersFacet;
}
