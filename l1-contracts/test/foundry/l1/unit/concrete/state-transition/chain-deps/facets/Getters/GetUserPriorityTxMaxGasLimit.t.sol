// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT, USER_PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";

contract GetUserPriorityTxMaxGasLimitTest is GettersFacetTest {
    /// A chain seeded with the default limit reports the EraVM user cap, not its own value.
    function test_eraVMChainAtDefaultLimitReturnsUserCap() public {
        gettersFacetWrapper.util_setPriorityTxMaxGasLimit(DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);

        assertEq(gettersFacet.getUserPriorityTxMaxGasLimit(), USER_PRIORITY_TX_MAX_GAS_LIMIT);
        assertEq(gettersFacet.getPriorityTxMaxGasLimit(), DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_eraVMChainStricterThanUserCapReturnsChainLimit() public {
        uint256 chainLimit = USER_PRIORITY_TX_MAX_GAS_LIMIT - 1;
        gettersFacetWrapper.util_setPriorityTxMaxGasLimit(chainLimit);

        assertEq(gettersFacet.getUserPriorityTxMaxGasLimit(), chainLimit);
    }

    function test_zksyncOSChainReturnsChainLimit() public {
        gettersFacetWrapper.util_setPriorityTxMaxGasLimit(DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);
        gettersFacetWrapper.util_setZksyncOS(true);

        assertEq(gettersFacet.getUserPriorityTxMaxGasLimit(), DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function testFuzz_returnsLowerOfChainLimitAndUserCapOnEraVM(uint256 _chainLimit) public {
        gettersFacetWrapper.util_setPriorityTxMaxGasLimit(_chainLimit);

        uint256 expected = _chainLimit < USER_PRIORITY_TX_MAX_GAS_LIMIT ? _chainLimit : USER_PRIORITY_TX_MAX_GAS_LIMIT;
        assertEq(gettersFacet.getUserPriorityTxMaxGasLimit(), expected);
    }
}
