// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {CommitmentTreeNotAppender} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    IMTAlreadyInitialized,
    IMTNotInitialized,
    IMTValueZero,
    IMTValueAlreadyExists
} from "contracts/common/L1ContractErrors.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @notice Unit tests for the thin {L2InteropCommitmentTree} shell: the appender ACL, the one-shot
/// `initialize` seed, the L2->L1 root publication on every seed/insert, and getter pass-through. The
/// underlying tree mechanics live in {IndexedMerkleTree} and are covered by its own suite, so here we
/// assert only what the shell adds; a couple of engine reverts are exercised to confirm they surface
/// unchanged through `insert`. The tree is deployed at its canonical address and left UN-initialized so
/// `initialize` can be tested from a clean slate; the L2->L1 messenger is mocked (a system contract, not
/// under test) so publishing does not revert.
contract L2InteropCommitmentTreeTest is AtomicInteropProofBuilder {
    uint256 internal constant VALUE_A = 100;
    uint256 internal constant VALUE_B = 200;
    address internal constant NOT_APPENDER = address(0xBAD);

    function setUp() public {
        _deployAtomicFixtures();
    }

    // ============ initialize ============

    function test_initialize_seedsSentinelLeafAndPublishes() public {
        // The seed root is published to L1 exactly once.
        vm.expectCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector)
        );
        vm.recordLogs();
        tree.initialize();

        assertEq(tree.leafCount(), 1, "seed leaf count");
        IMTLeaf memory seed = tree.leafAt(0);
        assertEq(seed.value, 0, "seed value");
        assertEq(seed.nextIndex, 0, "seed nextIndex");
        assertEq(seed.nextValue, 0, "seed nextValue");

        (uint256 leafIndex, bytes32 root, bool found) = _lastRootPublished(vm.getRecordedLogs());
        assertTrue(found, "RootPublished emitted");
        assertEq(leafIndex, 0, "seed leaf index");
        assertEq(root, tree.root(), "published root matches tree root");
    }

    /// @dev `initialize` is intentionally ACL-free (the appender is a fixed built-in; there is no wiring
    /// parameter), and the seed is deterministic, so an arbitrary caller cannot influence it.
    function test_initialize_isPermissionless() public {
        vm.prank(NOT_APPENDER);
        tree.initialize();
        assertEq(tree.leafCount(), 1, "seeded regardless of caller");
    }

    function test_RevertWhen_initializeTwice() public {
        tree.initialize();
        vm.expectRevert(IMTAlreadyInitialized.selector);
        tree.initialize();
    }

    // ============ insert ============

    function test_insert_appendsLeafAndPublishes() public {
        tree.initialize();

        uint256 low = _lowNullifierIndex(VALUE_A);
        vm.expectCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector)
        );
        vm.recordLogs();
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (uint256 newIndex, bytes32 newRoot) = tree.insert(VALUE_A, low);

        // First real leaf sits at index 1 (index 0 is the sentinel seed).
        assertEq(newIndex, 1, "new leaf index");
        assertEq(tree.leafCount(), 2, "leaf count after insert");
        assertEq(newRoot, tree.root(), "returned root matches tree root");

        IMTLeaf memory inserted = tree.leafAt(1);
        assertEq(inserted.value, VALUE_A, "inserted leaf value");
        // The sentinel is re-linked to point at the new leaf (sorted linked list).
        IMTLeaf memory seed = tree.leafAt(0);
        assertEq(seed.nextIndex, 1, "seed relinked nextIndex");
        assertEq(seed.nextValue, VALUE_A, "seed relinked nextValue");

        (uint256 leafIndex, bytes32 root, bool found) = _lastRootPublished(vm.getRecordedLogs());
        assertTrue(found, "RootPublished emitted");
        assertEq(leafIndex, 1, "published leaf index");
        assertEq(root, newRoot, "published root matches new root");
    }

    function test_RevertWhen_insertNotAppender() public {
        tree.initialize();
        vm.prank(NOT_APPENDER);
        vm.expectRevert(abi.encodeWithSelector(CommitmentTreeNotAppender.selector, NOT_APPENDER));
        tree.insert(VALUE_A, 0);
        // No leaf was appended.
        assertEq(tree.leafCount(), 1, "leaf count unchanged after unauthorized insert");
    }

    /// @dev Value/low-nullifier validation lives in the engine; these confirm the errors surface through
    /// the shell unchanged rather than being swallowed or re-wrapped.
    function test_RevertWhen_insertBeforeInitialize() public {
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectRevert(IMTNotInitialized.selector);
        tree.insert(VALUE_A, 0);
    }

    function test_RevertWhen_insertZeroValue() public {
        tree.initialize();
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectRevert(IMTValueZero.selector);
        tree.insert(0, 0);
    }

    function test_RevertWhen_insertDuplicateValue() public {
        tree.initialize();
        uint256 lowA = _lowNullifierIndex(VALUE_A);
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        tree.insert(VALUE_A, lowA);

        // The duplicate-value check fires before any low-leaf validation, so the low index is irrelevant.
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(IMTValueAlreadyExists.selector, VALUE_A));
        tree.insert(VALUE_A, 0);
    }

    // ============ getters ============

    function test_getters_reflectInsertedState() public {
        tree.initialize();
        uint256 lowA = _lowNullifierIndex(VALUE_A);
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        tree.insert(VALUE_A, lowA);
        bytes32 rootAfterA = tree.root();

        uint256 lowB = _lowNullifierIndex(VALUE_B);
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        tree.insert(VALUE_B, lowB);

        assertEq(tree.leafCount(), 3, "leaf count after two inserts");
        assertEq(tree.leafAt(1).value, VALUE_A, "leaf 1 value");
        assertEq(tree.leafAt(2).value, VALUE_B, "leaf 2 value");
        assertTrue(tree.root() != rootAfterA, "root changes on each insert");
        assertEq(tree.merklePath(2).length, tree.merklePath(1).length, "paths share the current tree height");
    }

    function test_appender_isFlowManager() public view {
        assertEq(tree.appender(), L2_ATOMIC_FLOW_MANAGER_ADDR);
    }

    // ============ helpers ============

    /// @dev Returns the last `RootPublished(uint256 indexed leafIndex, bytes32 root)` in `_logs`.
    function _lastRootPublished(
        Vm.Log[] memory _logs
    ) internal pure returns (uint256 leafIndex, bytes32 root, bool found) {
        bytes32 sig = IL2InteropCommitmentTree.RootPublished.selector;
        for (uint256 i = _logs.length; i > 0; --i) {
            Vm.Log memory entry = _logs[i - 1];
            if (entry.topics.length == 2 && entry.topics[0] == sig) {
                return (uint256(entry.topics[1]), abi.decode(entry.data, (bytes32)), true);
            }
        }
    }
}
