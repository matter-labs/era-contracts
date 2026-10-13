// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";

contract GetPriorityTxMaxGasLimitTest is GettersFacetTest {
    function testFuzz_returnsStoredLimit(uint256 _storedLimit) public {
        // Isolate the getter from initialization and upgrade-time normalization.
        gettersFacetWrapper.util_setPriorityTxMaxGasLimit(_storedLimit);
        assertEq(gettersFacet.getPriorityTxMaxGasLimit(), _storedLimit);
    }

    function test_boundaries() public {
        uint256[4] memory limits = [
            uint256(0),
            PRIORITY_TX_MAX_GAS_LIMIT - 1,
            PRIORITY_TX_MAX_GAS_LIMIT,
            type(uint256).max
        ];
        for (uint256 i; i < limits.length; i++) {
            gettersFacetWrapper.util_setPriorityTxMaxGasLimit(limits[i]);
            assertEq(gettersFacet.getPriorityTxMaxGasLimit(), limits[i]);
        }
    }
}
