// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {CommitmentTreeNotAppender} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IMTAlreadyInitialized} from "contracts/common/L1ContractErrors.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers the L2InteropCommitmentTree's access control and event contract. The tree is
/// consensus-critical (the bootloader snapshots its root into every chain batch root), so its two
/// write entry points must be locked down: `initL2` to the complex upgrader (genesis upgrade) and
/// `insert` to the canonical {AtomicFlowManager} — an open `insert` would let anyone plant commit
/// values, i.e. forge atomic-flow commitments. `RootUpdated` is the off-chain trace of every root
/// transition, so its exact payload (leaf index + resulting root) is asserted too.
/// The storage layout the bootloader reads is locked separately in
/// `L2InteropCommitmentTreeStorage.t.sol`.
contract L2InteropCommitmentTreeAccessTest is Test {
    L2InteropCommitmentTree internal tree;

    function setUp() public {
        tree = new L2InteropCommitmentTree();
    }

    function _initAsUpgrader() internal {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();
    }

    // ============ initL2 ============

    /// @notice Only the complex upgrader (the genesis upgrade path) may seed the tree.
    function test_RevertWhen_initL2NotUpgrader() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        tree.initL2();
    }

    /// @notice Seeding emits the genesis `RootUpdated`: head leaf index 0 and the canonical
    /// empty-IMT root (the exact value `ChainBatchRootTree.genesisChainBatchRoot()` bakes in).
    function test_initL2_EmitsGenesisRootUpdated() public {
        vm.expectEmit(true, true, true, true, address(tree));
        emit IL2InteropCommitmentTree.RootUpdated(0, ChainBatchRootTree.EMPTY_IMT_ROOT);
        _initAsUpgrader();
    }

    /// @notice The tree can only be seeded once; the engine rejects a second setup.
    function test_RevertWhen_initL2Twice() public {
        _initAsUpgrader();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(IMTAlreadyInitialized.selector);
        tree.initL2();
    }

    // ============ insert ============

    /// @notice `insert` is appender-gated to the canonical AtomicFlowManager: an open insert would
    /// let anyone plant arbitrary commit values into the consensus-critical tree.
    function test_RevertWhen_insertNotAppender() public {
        _initAsUpgrader();
        vm.expectRevert(abi.encodeWithSelector(CommitmentTreeNotAppender.selector, address(this)));
        tree.insert(uint256(keccak256("commit value")), 0);
    }

    /// @notice Every insert emits `RootUpdated` with the new leaf's index and the post-insert root —
    /// asserted against the values the call itself returns and the engine's own `root()`.
    function test_insert_EmitsRootUpdatedWithNewIndexAndRoot() public {
        _initAsUpgrader();
        uint256 value = uint256(keccak256("commit value"));

        // The insert's event payload is checked against an independent recomputation: the emitted
        // root must equal the engine root read back after the call, and the index the leaf count
        // position (1: right after the genesis head leaf).
        vm.recordLogs();
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (uint256 newIndex, bytes32 newRoot) = tree.insert(value, 0);

        assertEq(newIndex, 1, "first insert must land right after the genesis head leaf");
        assertEq(newRoot, tree.root(), "returned root must be the engine root");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "insert must emit exactly one event");
        assertEq(logs[0].topics[0], IL2InteropCommitmentTree.RootUpdated.selector, "event must be RootUpdated");
        assertEq(uint256(logs[0].topics[1]), newIndex, "indexed leaf index must be the new leaf's index");
        assertEq(abi.decode(logs[0].data, (bytes32)), newRoot, "emitted root must be the post-insert root");
    }
}
