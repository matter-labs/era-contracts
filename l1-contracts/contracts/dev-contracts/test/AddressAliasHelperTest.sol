// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";

contract AddressAliasHelperTest {
    function applyL1ToL2Alias(address _l1Address) external pure returns (address) {
        return AddressAliasHelper.applyL1ToL2Alias(_l1Address);
    }

    function undoL1ToL2Alias(address _l2Address) external pure returns (address) {
        return AddressAliasHelper.undoL1ToL2Alias(_l2Address);
    }
}
