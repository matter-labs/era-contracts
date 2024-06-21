// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriorityTreeTest, PriorityOpsBatchInfo} from "contracts/dev-contracts/test/PriorityTreeTest.sol";

contract PriorityTreeSharedTest is Test {
    PriorityTreeTest internal priorityTree;

    constructor() {
        priorityTree = new PriorityTreeTest();
    }

    // Pushes 'count' entries into the priority tree.
    function pushMockEntries(uint256 count) public returns (bytes32[] memory) {
        bytes32[] memory hashes = new bytes32[](count);
        for (uint256 i = 0; i < count; ++i) {
            bytes32 hash = keccak256(abi.encode(i));
            hashes[i] = hash;
            priorityTree.push(hash);
        }
        return hashes;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
