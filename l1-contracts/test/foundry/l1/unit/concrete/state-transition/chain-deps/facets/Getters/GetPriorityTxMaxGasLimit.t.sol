// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {Math} from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import {PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";

contract GetPriorityTxMaxGasLimitTest is GettersFacetTest {
    function testFuzz_returnsEffectiveLimit(uint256 _storedLimit) public {
        // Isolate the getter from admission/admin validation, including pre-upgrade stored limits.
        gettersFacetWrapper.util_setPriorityTxMaxGasLimit(_storedLimit);
        assertEq(gettersFacet.getPriorityTxMaxGasLimit(), Math.min(_storedLimit, PRIORITY_TX_MAX_GAS_LIMIT));
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
            assertEq(gettersFacet.getPriorityTxMaxGasLimit(), Math.min(limits[i], PRIORITY_TX_MAX_GAS_LIMIT));
        }
    }
}
