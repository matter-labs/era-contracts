// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract IsEthWithdrawalFinalizedTest is GettersFacetTest {
    function test() public {
        uint256 l2BatchNumber = 123456789;
        uint256 l2MessageIndex = 987654321;
        gettersFacetWrapper.util_setIsEthWithdrawalFinalized(l2BatchNumber, l2MessageIndex, true);

        bool received = gettersFacet.isEthWithdrawalFinalized(l2BatchNumber, l2MessageIndex);

        assertTrue(received, "isEthWithdrawalFinalized is incorrect");
    }
}
