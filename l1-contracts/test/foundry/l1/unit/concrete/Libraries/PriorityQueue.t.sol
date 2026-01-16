// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {PriorityQueue, PriorityOperation} from "contracts/state-transition/libraries/PriorityQueue.sol";
import {QueueIsEmpty} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for PriorityQueue library
contract PriorityQueueTest is Test {
    using PriorityQueue for PriorityQueue.Queue;

    PriorityQueue.Queue internal queue;

    // ============ isEmpty Tests ============

    function test_isEmpty_initiallyTrue() public view {
        assertTrue(queue.isEmpty());
    }

    function test_isEmpty_falseAfterPush() public {
        PriorityOperation memory op = _createOperation(keccak256("tx1"), 100, 0);
        queue.pushBack(op);

        assertFalse(queue.isEmpty());
    }

    function test_isEmpty_trueAfterPushAndPop() public {
        PriorityOperation memory op = _createOperation(keccak256("tx1"), 100, 0);
        queue.pushBack(op);
        queue.popFront();

        assertTrue(queue.isEmpty());
    }

    // ============ getSize Tests ============

    function test_getSize_initiallyZero() public view {
        assertEq(queue.getSize(), 0);
    }

    function test_getSize_incrementsOnPush() public {
        queue.pushBack(_createOperation(keccak256("tx1"), 100, 0));
        assertEq(queue.getSize(), 1);

        queue.pushBack(_createOperation(keccak256("tx2"), 200, 0));
        assertEq(queue.getSize(), 2);

        queue.pushBack(_createOperation(keccak256("tx3"), 300, 0));
        assertEq(queue.getSize(), 3);
    }

    function test_getSize_decrementsOnPop() public {
        queue.pushBack(_createOperation(keccak256("tx1"), 100, 0));
        queue.pushBack(_createOperation(keccak256("tx2"), 200, 0));
        assertEq(queue.getSize(), 2);

        queue.popFront();
        assertEq(queue.getSize(), 1);

        queue.popFront();
        assertEq(queue.getSize(), 0);
    }

    // ============ getTotalPriorityTxs Tests ============

    function test_getTotalPriorityTxs_initiallyZero() public view {
        assertEq(queue.getTotalPriorityTxs(), 0);
    }

    function test_getTotalPriorityTxs_incrementsOnPush() public {
        queue.pushBack(_createOperation(keccak256("tx1"), 100, 0));
        assertEq(queue.getTotalPriorityTxs(), 1);

        queue.pushBack(_createOperation(keccak256("tx2"), 200, 0));
        assertEq(queue.getTotalPriorityTxs(), 2);
    }

    function test_getTotalPriorityTxs_unchangedOnPop() public {
        queue.pushBack(_createOperation(keccak256("tx1"), 100, 0));
        queue.pushBack(_createOperation(keccak256("tx2"), 200, 0));
        assertEq(queue.getTotalPriorityTxs(), 2);

        queue.popFront();
        assertEq(queue.getTotalPriorityTxs(), 2); // Total doesn't decrease

        queue.popFront();
        assertEq(queue.getTotalPriorityTxs(), 2); // Total stays the same
    }

    // ============ getFirstUnprocessedPriorityTx Tests ============

    function test_getFirstUnprocessedPriorityTx_initiallyZero() public view {
        assertEq(queue.getFirstUnprocessedPriorityTx(), 0);
    }

    function test_getFirstUnprocessedPriorityTx_incrementsOnPop() public {
        queue.pushBack(_createOperation(keccak256("tx1"), 100, 0));
        queue.pushBack(_createOperation(keccak256("tx2"), 200, 0));

        assertEq(queue.getFirstUnprocessedPriorityTx(), 0);

        queue.popFront();
        assertEq(queue.getFirstUnprocessedPriorityTx(), 1);

        queue.popFront();
        assertEq(queue.getFirstUnprocessedPriorityTx(), 2);
    }

    // ============ pushBack Tests ============

    function test_pushBack_storesOperation() public {
        bytes32 txHash = keccak256("tx1");
        uint64 expiration = 12345;
        uint192 tip = 100;

        PriorityOperation memory op = _createOperation(txHash, expiration, tip);
        queue.pushBack(op);

        PriorityOperation memory stored = queue.front();
        assertEq(stored.canonicalTxHash, txHash);
        assertEq(stored.expirationTimestamp, expiration);
        assertEq(stored.layer2Tip, tip);
    }

    function test_pushBack_multipleOperations() public {
        for (uint256 i = 0; i < 10; i++) {
            queue.pushBack(_createOperation(bytes32(i), uint64(i * 100), uint192(i * 10)));
        }

        assertEq(queue.getSize(), 10);
        assertEq(queue.getTotalPriorityTxs(), 10);
    }

    // ============ front Tests ============

    function test_front_revertsOnEmptyQueue() public {
        vm.expectRevert(QueueIsEmpty.selector);
        queue.front();
    }

    function test_front_returnsFirstElement() public {
        bytes32 txHash1 = keccak256("tx1");
        bytes32 txHash2 = keccak256("tx2");

        queue.pushBack(_createOperation(txHash1, 100, 0));
        queue.pushBack(_createOperation(txHash2, 200, 0));

        PriorityOperation memory first = queue.front();
        assertEq(first.canonicalTxHash, txHash1);
    }

    function test_front_doesNotRemoveElement() public {
        queue.pushBack(_createOperation(keccak256("tx1"), 100, 0));

        queue.front();
        queue.front();
        queue.front();

        assertEq(queue.getSize(), 1); // Size unchanged
    }

    // ============ popFront Tests ============

    function test_popFront_revertsOnEmptyQueue() public {
        vm.expectRevert(QueueIsEmpty.selector);
        queue.popFront();
    }

    function test_popFront_returnsAndRemovesFirst() public {
        bytes32 txHash1 = keccak256("tx1");
        bytes32 txHash2 = keccak256("tx2");

        queue.pushBack(_createOperation(txHash1, 100, 0));
        queue.pushBack(_createOperation(txHash2, 200, 0));

        PriorityOperation memory popped = queue.popFront();
        assertEq(popped.canonicalTxHash, txHash1);
        assertEq(queue.getSize(), 1);

        PriorityOperation memory second = queue.front();
        assertEq(second.canonicalTxHash, txHash2);
    }

    function test_popFront_fifoOrder() public {
        bytes32 txHash1 = keccak256("tx1");
        bytes32 txHash2 = keccak256("tx2");
        bytes32 txHash3 = keccak256("tx3");

        queue.pushBack(_createOperation(txHash1, 100, 0));
        queue.pushBack(_createOperation(txHash2, 200, 0));
        queue.pushBack(_createOperation(txHash3, 300, 0));

        assertEq(queue.popFront().canonicalTxHash, txHash1);
        assertEq(queue.popFront().canonicalTxHash, txHash2);
        assertEq(queue.popFront().canonicalTxHash, txHash3);
    }

    // ============ Fuzz Tests ============

    function testFuzz_pushAndPop(uint8 numOps) public {
        vm.assume(numOps > 0 && numOps <= 100);

        // Push operations
        for (uint256 i = 0; i < numOps; i++) {
            queue.pushBack(_createOperation(bytes32(i), uint64(i), uint192(i)));
        }

        assertEq(queue.getSize(), numOps);
        assertEq(queue.getTotalPriorityTxs(), numOps);

        // Pop all and verify FIFO order
        for (uint256 i = 0; i < numOps; i++) {
            PriorityOperation memory op = queue.popFront();
            assertEq(op.canonicalTxHash, bytes32(i));
        }

        assertTrue(queue.isEmpty());
    }

    // ============ Helper Functions ============

    function _createOperation(
        bytes32 txHash,
        uint64 expiration,
        uint192 tip
    ) internal pure returns (PriorityOperation memory) {
        return PriorityOperation({canonicalTxHash: txHash, expirationTimestamp: expiration, layer2Tip: tip});
    }
}
