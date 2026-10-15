// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {PriorityOperation, PriorityQueue} from "contracts/state-transition/libraries/PriorityQueue.sol";
import {QueueIsEmpty} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for PriorityQueue library
contract PriorityQueueLibraryTest is Test {
    using PriorityQueue for PriorityQueue.Queue;

    uint256 internal constant NUMBER_OPERATIONS = 10;

    PriorityQueue.Queue internal queue;

    function test_emptyQueue() public view {
        assertEq(queue.getSize(), 0);
        assertEq(queue.getFirstUnprocessedPriorityTx(), 0);
        assertEq(queue.getTotalPriorityTxs(), 0);
        assertTrue(queue.isEmpty());
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

    // ============ front Tests ============

    function test_front() public {
        _pushMockEntries(NUMBER_OPERATIONS);

        PriorityOperation memory front = queue.front();
        assertEq(front.canonicalTxHash, keccak256(abi.encode(0)));
        assertEq(front.expirationTimestamp, 0);
        assertEq(front.layer2Tip, 0);

        // `front` doesn't remove the element.
        assertEq(queue.getSize(), NUMBER_OPERATIONS);
        assertEq(queue.getFirstUnprocessedPriorityTx(), 0);
        assertEq(queue.getTotalPriorityTxs(), NUMBER_OPERATIONS);
        assertFalse(queue.isEmpty());
    }

    function test_front_revertsOnEmptyQueue() public {
        vm.expectRevert(QueueIsEmpty.selector);
        queue.front();
    }

    // ============ popFront Tests ============

    function test_popFront() public {
        _pushMockEntries(NUMBER_OPERATIONS);

        PriorityOperation memory front = queue.popFront();
        assertEq(front.canonicalTxHash, keccak256(abi.encode(0)));
        assertEq(front.expirationTimestamp, 0);
        assertEq(front.layer2Tip, 0);

        assertEq(queue.getSize(), NUMBER_OPERATIONS - 1);
        assertEq(queue.getFirstUnprocessedPriorityTx(), 1);
        assertEq(queue.getTotalPriorityTxs(), NUMBER_OPERATIONS);
        assertFalse(queue.isEmpty());

        PriorityOperation memory front2 = queue.popFront();
        assertEq(front2.canonicalTxHash, keccak256(abi.encode(1)));
        assertEq(front2.expirationTimestamp, 1);
        assertEq(front2.layer2Tip, 1);

        assertEq(queue.getSize(), NUMBER_OPERATIONS - 2);
        assertEq(queue.getFirstUnprocessedPriorityTx(), 2);
        assertEq(queue.getTotalPriorityTxs(), NUMBER_OPERATIONS);
        assertFalse(queue.isEmpty());
    }

    function test_popFront_untilEmptyThenPushAgain() public {
        _pushMockEntries(NUMBER_OPERATIONS);
        for (uint256 i = 0; i < NUMBER_OPERATIONS; ++i) {
            assertEq(queue.popFront().canonicalTxHash, keccak256(abi.encode(i)));
        }

        assertEq(queue.getSize(), 0);
        assertEq(queue.getFirstUnprocessedPriorityTx(), NUMBER_OPERATIONS);
        assertEq(queue.getTotalPriorityTxs(), NUMBER_OPERATIONS);
        assertTrue(queue.isEmpty());

        queue.pushBack(_createOperation(keccak256(abi.encode(300)), 300, 300));

        assertEq(queue.getSize(), 1);
        assertEq(queue.getFirstUnprocessedPriorityTx(), NUMBER_OPERATIONS);
        assertEq(queue.getTotalPriorityTxs(), NUMBER_OPERATIONS + 1);
        assertFalse(queue.isEmpty());

        assertEq(queue.popFront().canonicalTxHash, keccak256(abi.encode(300)));
        assertTrue(queue.isEmpty());

        vm.expectRevert(QueueIsEmpty.selector);
        queue.popFront();
    }

    function test_popFront_revertsOnEmptyQueue() public {
        vm.expectRevert(QueueIsEmpty.selector);
        queue.popFront();
    }

    // ============ Fuzz Tests ============

    function testFuzz_pushAndPop(uint8 _numOps) public {
        vm.assume(_numOps > 0 && _numOps <= 100);

        for (uint256 i = 0; i < _numOps; i++) {
            queue.pushBack(_createOperation(bytes32(i), uint64(i), uint192(i)));
        }

        assertEq(queue.getSize(), _numOps);
        assertEq(queue.getTotalPriorityTxs(), _numOps);

        for (uint256 i = 0; i < _numOps; i++) {
            PriorityOperation memory op = queue.popFront();
            assertEq(op.canonicalTxHash, bytes32(i));
        }

        assertTrue(queue.isEmpty());
    }

    // ============ Helper Functions ============

    function _pushMockEntries(uint256 _count) internal {
        for (uint256 i = 0; i < _count; ++i) {
            queue.pushBack(_createOperation(keccak256(abi.encode(i)), uint64(i), uint192(i)));
        }
    }

    function _createOperation(
        bytes32 _txHash,
        uint64 _expiration,
        uint192 _tip
    ) internal pure returns (PriorityOperation memory) {
        return PriorityOperation({canonicalTxHash: _txHash, expirationTimestamp: _expiration, layer2Tip: _tip});
    }
}
