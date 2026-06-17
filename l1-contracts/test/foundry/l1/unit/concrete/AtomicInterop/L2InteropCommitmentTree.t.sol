// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {IndexedMerkleTreeLib, IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {
    CommitmentTreeAlreadyInitialized,
    CommitmentTreeNotAppender,
    CommitmentTreeZeroAppender
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    IMTValueZero,
    IMTValueAlreadyExists,
    IMTLowLeafValueTooLarge,
    IMTLowLeafNextTooSmall
} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {AtomicInteropTestUtils} from "./AtomicInteropTestUtils.sol";

/// @notice Unit tests for the {L2InteropCommitmentTree} shell over the shared IMT engine. The shell
/// owns the appender ACL, the `initialize` wiring, and the L2->L1 root publication; value / low-leaf
/// validation is delegated to the engine and surfaces its `IMT*` errors.
///
/// The test contract installs the L2->L1 messenger mock (so the `sendToL1` in `initialize`/`insert`
/// succeeds) and registers itself as the appender so it can call `insert` directly.
contract L2InteropCommitmentTreeTest is Test {
    /// @dev Mirror of the event so tests can `vm.expectEmit` against it.
    event RootPublished(uint256 indexed leafIndex, bytes32 root);

    L2InteropCommitmentTree internal tree;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        AtomicInteropTestUtils.installSystemMocks();
        tree = new L2InteropCommitmentTree();
        // This test contract acts as the appender so it can call insert directly.
        tree.initialize(address(this));
    }

    // ── initialize ───────────────────────────────────────────────────────────────────────────

    function test_initialize_seedsHeadLeafOnce() public {
        assertEq(tree.appender(), address(this));
        assertEq(tree.leafCount(), 1);
        IMTLeaf memory head = tree.leafAt(0);
        assertEq(head.value, 0);
        assertEq(head.nextIndex, 0);
        assertEq(head.nextValue, 0);

        vm.expectRevert(CommitmentTreeAlreadyInitialized.selector);
        tree.initialize(address(this));
    }

    function test_initialize_revertsOnZeroAppender() public {
        L2InteropCommitmentTree fresh = new L2InteropCommitmentTree();
        vm.expectRevert(CommitmentTreeZeroAppender.selector);
        fresh.initialize(address(0));
    }

    function test_initialize_publishesSeedRoot() public {
        L2InteropCommitmentTree fresh = new L2InteropCommitmentTree();
        // The seed root is published at leafIndex 0. We don't pin the exact root here (it is asserted in
        // the insert test); just that the head-seed event is emitted.
        vm.expectEmit(true, false, false, false);
        emit RootPublished(0, bytes32(0));
        fresh.initialize(address(this));
    }

    // ── insert / sorted linked list ─────────────────────────────────────────────────────────

    function test_insert_maintainsSortedLinkedList() public {
        tree.insert(100, 0); // head -> 100 @ idx 1
        tree.insert(300, 1); // 100 -> 300 @ idx 2
        tree.insert(200, 1); // 100 -> 200 @ idx 3 -> 300 (spliced between)

        assertEq(tree.leafCount(), 4);

        // head{0, nextIndex:1, nextValue:100} — note IMTLeaf field order (value, nextIndex, nextValue).
        IMTLeaf memory head = tree.leafAt(0);
        assertEq(head.nextIndex, 1);
        assertEq(head.nextValue, 100);

        // leaf1 (value 100) now points to 200 at index 3
        IMTLeaf memory l1 = tree.leafAt(1);
        assertEq(l1.value, 100);
        assertEq(l1.nextIndex, 3);
        assertEq(l1.nextValue, 200);

        // leaf3 (value 200) points to 300 at index 2
        IMTLeaf memory l3 = tree.leafAt(3);
        assertEq(l3.value, 200);
        assertEq(l3.nextIndex, 2);
        assertEq(l3.nextValue, 300);

        // leaf2 (value 300) is the max — tail of the list
        IMTLeaf memory l2 = tree.leafAt(2);
        assertEq(l2.value, 300);
        assertEq(l2.nextIndex, 0);
        assertEq(l2.nextValue, 0);
    }

    function test_insert_emitsRootPublished() public {
        // The first insert lands at leafIndex 1 and publishes the new root (no timestamp is bundled —
        // the deadline anchor is the settlement-layer block number, derived later from the proof). The
        // root is only known after the insert, so rather than pre-arming `vm.expectEmit` we record logs
        // and assert the full `RootPublished` payload against the values `insert` returns.
        vm.recordLogs();
        (uint256 idx, bytes32 root) = tree.insert(100, 0);

        assertEq(idx, 1, "first inserted leaf at index 1");
        assertEq(tree.root(), root, "stored root tracks insert");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("RootPublished(uint256,bytes32)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(tree)) continue;
            assertEq(uint256(logs[i].topics[1]), idx, "event leafIndex");
            bytes32 evRoot = abi.decode(logs[i].data, (bytes32));
            assertEq(evRoot, root, "event root matches returned root");
            found = true;
        }
        assertTrue(found, "RootPublished emitted on insert");
    }

    // ── inclusion path round-trip ────────────────────────────────────────────────────────────

    function test_insert_inclusionPathVerifies() public {
        tree.insert(100, 0);
        tree.insert(300, 1);
        tree.insert(200, 1);

        uint256 idx = AtomicInteropTestUtils.indexOfValue(tree, 200);
        IMTLeaf memory leaf = tree.leafAt(idx);
        bytes32[] memory path = tree.merklePath(idx);
        assertTrue(
            IndexedMerkleTreeLib.verifyInclusion(tree.root(), 200, leaf, idx, path),
            "inclusion path verifies against tree root"
        );
    }

    // ── low-nullifier bracketing ─────────────────────────────────────────────────────────────

    function test_lowNullifier_bracketsAbsentValues() public {
        tree.insert(100, 0);
        tree.insert(300, 1);
        tree.insert(200, 1);

        assertEq(AtomicInteropTestUtils.lowNullifierIndex(tree, 50), 0, "below all -> head");
        assertEq(AtomicInteropTestUtils.lowNullifierIndex(tree, 250), 3, "between 200 and 300 -> idx of 200");
        assertEq(AtomicInteropTestUtils.lowNullifierIndex(tree, 400), 2, "above all -> idx of 300");
    }

    // ── ACL / validation ─────────────────────────────────────────────────────────────────────
    // (validation errors below surface the engine's `IMT*` errors through the shell)

    function test_insert_onlyAppender() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CommitmentTreeNotAppender.selector, stranger));
        tree.insert(100, 0);
    }

    function test_insert_revertsOnZeroValue() public {
        vm.expectRevert(IMTValueZero.selector);
        tree.insert(0, 0);
    }

    function test_insert_revertsOnDuplicateValue() public {
        tree.insert(100, 0);
        vm.expectRevert(abi.encodeWithSelector(IMTValueAlreadyExists.selector, uint256(100)));
        tree.insert(100, 1);
    }

    function test_insert_revertsWhenLowLeafValueTooLarge() public {
        tree.insert(100, 0); // head -> 100
        // 50 is below leaf1's value (100), so leaf1 cannot be its low-nullifier.
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafValueTooLarge.selector, uint256(100), uint256(50)));
        tree.insert(50, 1);
    }

    function test_insert_revertsWhenLowLeafNextTooSmall() public {
        tree.insert(100, 0); // head -> 100, head.nextValue == 100
        // 150's true low-nullifier is leaf1 (100); the head's next (100) <= 150, so the head is wrong.
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafNextTooSmall.selector, uint256(100), uint256(150)));
        tree.insert(150, 0);
    }
}
