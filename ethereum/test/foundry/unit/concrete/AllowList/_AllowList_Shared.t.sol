// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {AllowList} from "../../../../../cache/solpp-generated-contracts/common/AllowList.sol";

contract AllowListTest is Test {
    AllowList internal allowList;
    address internal owner = makeAddr("owner");
    address internal randomSigner = makeAddr("randomSigner");

    function setUp() public {
        allowList = new AllowList(owner);
    }
}
