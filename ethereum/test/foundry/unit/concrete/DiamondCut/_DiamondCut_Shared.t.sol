// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// solhint-disable max-line-length

import {Test} from "forge-std/Test.sol";
import {DiamondCutTestContract} from "../../../../../cache/solpp-generated-contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {GettersFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";

// solhint-enable max-line-length

contract DiamondCutTest is Test {
    DiamondCutTestContract internal diamondCutTestContract;
    GettersFacet internal gettersFacet;
}
