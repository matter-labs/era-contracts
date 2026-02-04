// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";

contract GetPubdataPricingModeTest is GettersFacetTest {
    function test_rollup() public {
        gettersFacetWrapper.util_setPubdataPricingMode(uint8(PubdataPricingMode.Rollup));

        PubdataPricingMode received = gettersFacet.getPubdataPricingMode();

        assertEq(uint8(received), uint8(PubdataPricingMode.Rollup), "Pubdata pricing mode is incorrect");
    }

    function test_validium() public {
        gettersFacetWrapper.util_setPubdataPricingMode(uint8(PubdataPricingMode.Validium));

        PubdataPricingMode received = gettersFacet.getPubdataPricingMode();

        assertEq(uint8(received), uint8(PubdataPricingMode.Validium), "Pubdata pricing mode is incorrect");
    }
}
