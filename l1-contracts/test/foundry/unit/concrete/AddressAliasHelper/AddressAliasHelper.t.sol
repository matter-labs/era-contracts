// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {AddressAliasHelperTest} from "solpp/dev-contracts/test/AddressAliasHelperTest.sol";

contract UtilsTest is Test {
    AddressAliasHelperTest addressAliasHelper;

    function setUp() public {
        addressAliasHelper = new AddressAliasHelperTest();
    }

    function testL2toL1AddressConversion() public {
        address[2] memory l2Addresses = [0x1111000000000000000000000000000000001110, 0x1111000000000000000000000000081759a885c4];
        address[2] memory l1ExpectedAddresses = [0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF, 0x0000000000000000000000000000081759a874B3];

        for (uint i; i < l2Addresses.length; i++) {
            address l1Address = addressAliasHelper.undoL1ToL2Alias(l2Addresses[i]);

            assertEq(
                l1Address,
                l1ExpectedAddresses[i],
                "L2 to L1 address conversion is not correct"
            );
        }
    }

    function testL1toL2AddressConversion() public {
        address[2] memory l1Addresses = [0xEEeEfFfffffFffFFFFffFFffFfFfFfffFfFFEEeE, 0x0000000000000000000000000000081759a874B3];
        address[2] memory l2ExpectedAddresses = [0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF, 0x1111000000000000000000000000081759a885c4];

        for (uint i; i < l1Addresses.length; i++) {
            address l2Address = addressAliasHelper.applyL1ToL2Alias(l1Addresses[i]);

            assertEq(
                l2Address,
                l2ExpectedAddresses[i],
                "L1 to L2 address conversion is not correct"
            );
        }
    }
}