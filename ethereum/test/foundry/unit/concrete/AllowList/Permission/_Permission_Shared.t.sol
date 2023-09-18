// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {AllowListTest} from "../_AllowList_Shared.t.sol";

contract PermissionTest is AllowListTest {
    address internal target = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    bytes4 internal functionSig = 0x1626ba7e;
}
