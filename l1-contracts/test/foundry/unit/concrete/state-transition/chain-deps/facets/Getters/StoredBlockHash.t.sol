// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract StoredBlockHashTest is GettersFacetTest {
    function test() public {
        uint256 batchNumber = 42;
        bytes32 expected = keccak256("Stored Batch Hash");
        gettersFacetWrapper.util_setStoredBatchHash(batchNumber, expected);

        bytes32 received = legacyGettersFacet.storedBlockHash(batchNumber);

        assertEq(expected, received, "Stored Batch Hash is incorrect");
    }
}
