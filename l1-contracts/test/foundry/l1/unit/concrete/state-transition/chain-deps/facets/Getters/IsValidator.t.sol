// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract IsValidatorTest is GettersFacetTest {
    function test_validator() public {
        address validator = makeAddr("validator");
        gettersFacetWrapper.util_setValidator(validator, true);

        bool received = gettersFacet.isValidator(validator);

        assertTrue(received, "Address should be validator");
    }

    function test_notValidator() public {
        address validator = makeAddr("validator");
        gettersFacetWrapper.util_setValidator(validator, false);

        bool received = gettersFacet.isValidator(validator);

        assertFalse(received, "Address should not be validator");
    }
}
