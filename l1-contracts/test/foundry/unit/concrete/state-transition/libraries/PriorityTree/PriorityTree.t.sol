// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {PriorityTreeSharedTest, PriorityOpsBatchInfo} from "./_PriorityTree_Shared.t.sol";

contract PriorityTreeTest is PriorityTreeSharedTest {
    function test_gets() public {
        assertEq(0, priorityTree.getSize());
        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());
        assertEq(0, priorityTree.getTotalPriorityTxs());
        assertEq(bytes32(0), priorityTree.getRoot());
    }

    function test_push() public {
        priorityTree.push(keccak256(abi.encode(1)));
        priorityTree.push(keccak256(abi.encode(2)));

        assertEq(2, priorityTree.getSize());
        assertEq(0, priorityTree.getFirstUnprocessedPriorityTx());
        assertEq(2, priorityTree.getTotalPriorityTxs());

        bytes32 expectedRoot = keccak256(abi.encode(keccak256(abi.encode(1)), keccak256(abi.encode(2))));
        assertEq(expectedRoot, priorityTree.getRoot());
    }

    function test_processBatch_shouldRevert() public {
        // TODO
    }
}
