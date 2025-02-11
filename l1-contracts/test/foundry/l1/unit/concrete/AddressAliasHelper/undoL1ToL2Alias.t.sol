// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AddressAliasHelperSharedTest} from "./_AddressAliasHelper_Shared.t.sol";

contract undoL1ToL2AliasTest is AddressAliasHelperSharedTest {
    function testL2toL1AddressConversion() public {
        address[2] memory l2Addresses = [
            0x1111000000000000000000000000000000001110,
            0x1111000000000000000000000000081759a885c4
        ];
        address[2] memory l1ExpectedAddresses = [
            0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF,
            0x0000000000000000000000000000081759a874B3
        ];

        for (uint256 i; i < l2Addresses.length; i++) {
            address l1Address = addressAliasHelper.undoL1ToL2Alias(l2Addresses[i]);

            assertEq(l1Address, l1ExpectedAddresses[i], "L2 to L1 address conversion is not correct");
        }
    }
}
