// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetL2DefaultAccountBytecodeHashTest is GettersFacetTest {
    function test() public {
        bytes32 expected = keccak256("L2 Default Account Bytecode Hash");
        gettersFacetWrapper.util_setL2DefaultAccountBytecodeHash(expected);

        bytes32 received = gettersFacet.getL2DefaultAccountBytecodeHash();

        assertEq(expected, received, "L2 Default Account Bytecode Hash is incorrect");
    }
}
