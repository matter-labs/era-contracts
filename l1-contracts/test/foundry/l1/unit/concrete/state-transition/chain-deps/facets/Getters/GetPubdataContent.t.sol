// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";
import {PubdataContent} from "contracts/common/Config.sol";

contract GetPubdataContentTest is GettersFacetTest {
    function test_defaultsToFullPubdata() public {
        // Fresh storage: the enum's zero value must read as FULL_PUBDATA (commit everything),
        // so chains that existed before the field was introduced keep full-pubdata behavior.
        PubdataContent received = gettersFacet.getPubdataContent();

        assertEq(uint8(received), uint8(PubdataContent.FULL_PUBDATA), "Default pubdata content is incorrect");
    }

    function test_logsOnly() public {
        gettersFacetWrapper.util_setPubdataContent(uint8(PubdataContent.LOGS_ONLY));

        PubdataContent received = gettersFacet.getPubdataContent();

        assertEq(uint8(received), uint8(PubdataContent.LOGS_ONLY), "Received pubdata content is incorrect");
    }

    function test_fullPubdata() public {
        gettersFacetWrapper.util_setPubdataContent(uint8(PubdataContent.FULL_PUBDATA));

        PubdataContent received = gettersFacet.getPubdataContent();

        assertEq(uint8(received), uint8(PubdataContent.FULL_PUBDATA), "Received pubdata content is incorrect");
    }
}
