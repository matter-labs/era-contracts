// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AddressAliasHelperSharedTest} from "./_AddressAliasHelper_Shared.t.sol";

contract applyL1ToL2AliasTest is AddressAliasHelperSharedTest {
    function testL1toL2AddressConversion() public {
        address[2] memory l1Addresses = [
            0xEEeEfFfffffFffFFFFffFFffFfFfFfffFfFFEEeE,
            0x0000000000000000000000000000081759a874B3
        ];
        address[2] memory l2ExpectedAddresses = [
            0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF,
            0x1111000000000000000000000000081759a885c4
        ];

        for (uint256 i; i < l1Addresses.length; i++) {
            address l2Address = addressAliasHelper.applyL1ToL2Alias(l1Addresses[i]);

            assertEq(l2Address, l2ExpectedAddresses[i], "L1 to L2 address conversion is not correct");
        }
    }
}
