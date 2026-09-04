// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {IMTLeaf, IndexedMerkleTree} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {CommitmentTreeNotAppender} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/SystemContractErrors.sol";
import {
    IMTAlreadyInitialized,
    IMTNotInitialized,
    IMTValueZero,
    IMTValueAlreadyExists
} from "contracts/common/L1ContractErrors.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Unit tests for the thin {L2InteropCommitmentTree} shell: the one-shot upgrader-gated `initL2`
/// seed, the appender-gated `insert`, the `RootUpdated` event, and getter pass-through. The tree publishes
/// nothing to L1 (the bootloader reads the root from storage at batch boundaries), so the only observable
/// output the shell adds on top of the {IndexedMerkleTree} engine is that event; every mutation asserts its
/// exact payload (leaf index + root) against the resulting on-chain state. The underlying tree mechanics are
/// covered by the engine's own suite, so a couple of engine reverts are exercised only to confirm they
/// surface unchanged through `insert`.
///
/// The tree is deployed and left UN-initialized so `initL2` can be tested from a clean slate. This is a
/// standalone fixture (not the shared {AtomicInteropProofBuilder}), since the tree needs no proof machinery.
contract L2InteropCommitmentTreeTest is Test {
    uint256 internal constant VALUE_A = 100;
    uint256 internal constant VALUE_B = 200;
    address internal constant STRANGER = address(0xBAD);

    L2InteropCommitmentTree internal tree;

    function setUp() public {
        tree = new L2InteropCommitmentTree();
    }

    // ============ initL2 ============

    function test_initL2_seedsSentinelLeafAndEmitsRootUpdated() public {
        vm.recordLogs();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();

        // Storage: exactly the `{0,0,0}` head leaf at index 0.
        assertEq(tree.leafCount(), 1, "seed leaf count");
        IMTLeaf memory seed = tree.leafAt(0);
        assertEq(seed.value, 0, "seed value");
        assertEq(seed.nextIndex, 0, "seed nextIndex");
        assertEq(seed.nextValue, 0, "seed nextValue");

        // Event: exactly one RootUpdated from the tree, carrying the seed root at index 0.
        _assertSingleRootUpdated(vm.getRecordedLogs(), 0, tree.root());
    }

    /// @dev `initL2` is gated to the complex upgrader (the genesis-upgrade caller); no one else can seed.
    function test_RevertWhen_initL2NotUpgrader() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, STRANGER));
        tree.initL2();
    }

    function test_RevertWhen_initL2Twice() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(IMTAlreadyInitialized.selector);
        tree.initL2();
    }

    // ============ insert ============

    function test_insert_appendsLeafAndEmitsRootUpdated() public {
        _initTree();

        uint256 low = _lowNullifierIndex(VALUE_A);
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

        // Event: exactly one RootUpdated from the tree, carrying the exact new index + root the insert produced.
        _assertSingleRootUpdated(vm.getRecordedLogs(), newIndex, newRoot);
    }

    /// @dev Regression guard for the emitted leaf index: a second insert must report index 2, not a
    /// constant 1. This is the only test that asserts the event payload of a non-first mutation — without
    /// it a shell that always emitted `RootUpdated(1, ...)` would stay green.
    function test_insert_secondInsertEmitsRootUpdatedWithIncrementedIndex() public {
        _initTree();

        uint256 lowA = _lowNullifierIndex(VALUE_A);
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        tree.insert(VALUE_A, lowA);

        uint256 lowB = _lowNullifierIndex(VALUE_B);
        vm.recordLogs();
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (uint256 newIndex, bytes32 newRoot) = tree.insert(VALUE_B, lowB);

        // Second real leaf sits at index 2 (0 = sentinel, 1 = VALUE_A).
        assertEq(newIndex, 2, "second insert leaf index");
        assertEq(newRoot, tree.root(), "returned root matches tree root");
        _assertSingleRootUpdated(vm.getRecordedLogs(), newIndex, newRoot);
    }

    function test_RevertWhen_insertNotAppender() public {
        _initTree();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(CommitmentTreeNotAppender.selector, STRANGER));
        tree.insert(VALUE_A, 0);
        // No leaf was appended.
        assertEq(tree.leafCount(), 1, "leaf count unchanged after unauthorized insert");
    }

    /// @dev Value/low-nullifier validation lives in the engine; these confirm the errors surface through
    /// the shell unchanged rather than being swallowed or re-wrapped.
    function test_RevertWhen_insertBeforeInitL2() public {
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectRevert(IMTNotInitialized.selector);
        tree.insert(VALUE_A, 0);
    }

    function test_RevertWhen_insertZeroValue() public {
        _initTree();
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectRevert(IMTValueZero.selector);
        tree.insert(0, 0);
    }

    function test_RevertWhen_insertDuplicateValue() public {
        _initTree();
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
        _initTree();
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

        // `merklePath` must forward the index and return a real inclusion path (equal path lengths alone
        // prove nothing — both share the current tree height): recompute the root from each path + the
        // full `leafAt(index)` preimage + the index, and require it to match `root()`. A shell that
        // ignored `_index` (e.g. always returned `merklePath(1)`) would fail for index 2.
        _assertPathAuthenticatesLeaf(1);
        _assertPathAuthenticatesLeaf(2);
    }

    function test_appender_isFlowManager() public view {
        assertEq(tree.appender(), L2_ATOMIC_FLOW_MANAGER_ADDR);
    }

    // ============ helpers ============

    /// @dev Seeds the tree as the genesis upgrader.
    function _initTree() internal {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();
    }

    /// @dev Finds the leaf that brackets `_value` in the sorted linked list (its low-nullifier).
    function _lowNullifierIndex(uint256 _value) internal view returns (uint256) {
        uint256 count = tree.leafCount();
        for (uint256 i = 0; i < count; ++i) {
            IMTLeaf memory leaf = tree.leafAt(i);
            if (leaf.value < _value && (leaf.nextValue == 0 || leaf.nextValue > _value)) {
                return i;
            }
        }
        revert("no low-nullifier (value present or tree empty)");
    }

    /// @dev Asserts `_logs` holds exactly one `RootUpdated(uint256 indexed leafIndex, bytes32 root)`
    /// emitted BY THE TREE, carrying `_expectedIndex` and `_expectedRoot`. Enforcing the emitter and the
    /// cardinality (rather than just picking the last matching log) means a stray, duplicate, or
    /// foreign-emitter `RootUpdated` fails the assertion instead of being silently accepted.
    function _assertSingleRootUpdated(
        Vm.Log[] memory _logs,
        uint256 _expectedIndex,
        bytes32 _expectedRoot
    ) internal view {
        bytes32 sig = IL2InteropCommitmentTree.RootUpdated.selector;
        uint256 count;
        uint256 leafIndex;
        bytes32 root;
        for (uint256 i = 0; i < _logs.length; ++i) {
            Vm.Log memory entry = _logs[i];
            if (entry.emitter == address(tree) && entry.topics.length == 2 && entry.topics[0] == sig) {
                ++count;
                leafIndex = uint256(entry.topics[1]);
                root = abi.decode(entry.data, (bytes32));
            }
        }
        assertEq(count, 1, "exactly one RootUpdated emitted by the tree");
        assertEq(leafIndex, _expectedIndex, "RootUpdated leaf index");
        assertEq(root, _expectedRoot, "RootUpdated root");
    }

    /// @dev Asserts `merklePath(_index)` authenticates `leafAt(_index)` against the current root: recompute
    /// the root from the returned path, the full leaf preimage, and the index (via the same engine the real
    /// proofs use). This catches a getter that fails to forward `_index` or returns a non-authenticating path.
    function _assertPathAuthenticatesLeaf(uint256 _index) internal view {
        IMTLeaf memory leaf = tree.leafAt(_index);
        bytes32[] memory path = tree.merklePath(_index);
        assertTrue(
            IndexedMerkleTree.verifyInclusion(tree.root(), leaf.value, leaf, _index, path),
            "merklePath authenticates leafAt(index) against root"
        );
    }
}
