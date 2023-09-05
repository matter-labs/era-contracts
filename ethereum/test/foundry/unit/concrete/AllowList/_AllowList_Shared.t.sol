// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../../../../cache/solpp-generated-contracts/common/AllowList.sol";
import "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";

contract AllowListTest is Test {
    AllowList allowList;
    address owner = makeAddr("owner");
    address randomSigner = makeAddr("randomSigner");

    function setUp() public {
        allowList = new AllowList(owner);
    }
}
