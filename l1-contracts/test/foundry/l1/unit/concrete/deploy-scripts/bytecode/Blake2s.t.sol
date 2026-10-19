// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Blake2s} from "deploy-scripts/utils/bytecode/Blake2s.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";

/// @notice `Blake2s` hashes through `scripts/blake2s256.js`; these tests run it over FFI.
contract Blake2sTest is Test {
    string internal scratchFile;

    function setUp() public {
        scratchFile = string.concat(vm.projectRoot(), "/script-out/blake2s-test-batch.txt");
    }

    function test_hash_matchesKnownVector() public {
        assertEq(
            Blake2s.hash(bytes("hello world")),
            0x9aec6806794561107e594b1f6a8a6b0c92a0cba9acf5e5e93cca06f781813b0b,
            "blake2s-256 of 'hello world'"
        );
    }

    function test_hashBatch_matchesHashPerElement() public {
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = bytes("hello world");
        inputs[1] = BytecodeUtils.readDeployedBytecodeL1("EmptyContract.sol", "EmptyContract");
        inputs[2] = BytecodeUtils.readDeployedBytecodeL1("SystemContractProxy.sol", "SystemContractProxy");

        bytes32[] memory hashes = Blake2s.hashBatch(inputs, scratchFile);

        assertEq(hashes.length, inputs.length, "one hash per input");
        for (uint256 i = 0; i < inputs.length; i++) {
            assertEq(hashes[i], Blake2s.hash(inputs[i]), "batch hash differs from the single hash");
        }
        assertFalse(vm.exists(scratchFile), "the scratch file is removed");
    }

    function test_hashBatch_emptyBatch() public {
        bytes32[] memory hashes = Blake2s.hashBatch(new bytes[](0), scratchFile);

        assertEq(hashes.length, 0, "no input, no hash");
        assertFalse(vm.exists(scratchFile), "the scratch file is removed");
    }
}
