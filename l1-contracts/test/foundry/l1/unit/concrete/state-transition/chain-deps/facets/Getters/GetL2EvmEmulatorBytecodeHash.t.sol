// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GettersFacetTest} from "./_Getters_Shared.t.sol";

contract GetL2EvmEmulatorBytecodeHashTest is GettersFacetTest {
    function test() public {
        bytes32 expected = bytes32(uint256(0x1234567890abcdef));
        gettersFacetWrapper.utils_setL2EvmEmulatorBytecodeHash(expected);

        bytes32 received = gettersFacet.getL2EvmEmulatorBytecodeHash();

        assertEq(expected, received, "L2 EVM Emulator bytecode hash is incorrect");
    }

    function test_fuzz(bytes32 _bytecodeHash) public {
        gettersFacetWrapper.utils_setL2EvmEmulatorBytecodeHash(_bytecodeHash);

        bytes32 received = gettersFacet.getL2EvmEmulatorBytecodeHash();

        assertEq(_bytecodeHash, received, "L2 EVM Emulator bytecode hash is incorrect");
    }
}
