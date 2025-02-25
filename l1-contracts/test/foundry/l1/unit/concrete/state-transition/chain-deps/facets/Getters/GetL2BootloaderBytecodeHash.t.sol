// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetL2BootloaderBytecodeHashTest is GettersFacetTest {
    function test() public {
        bytes32 expected = keccak256("L2 Bootloader Bytecode Hash");
        gettersFacetWrapper.util_setL2BootloaderBytecodeHash(expected);

        bytes32 received = gettersFacet.getL2BootloaderBytecodeHash();

        assertEq(expected, received, "L2 Bootloader Bytecode Hash is incorrect");
    }
}
