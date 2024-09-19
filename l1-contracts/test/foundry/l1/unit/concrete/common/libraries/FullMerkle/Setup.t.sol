// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMerkleTest} from "./_FullMerkle_Shared.t.sol";

contract SetupTest is FullMerkleTest {
    function test_checkInit() public view {
        assertEq(merkleTest.height(), 0, "Height should be 0");
        assertEq(merkleTest.index(), 0, "Leaf number should be 0");
        assertEq(merkleTest.zeros(0), zeroHash, "Zero hash should be correctly initialized");
    }
}
