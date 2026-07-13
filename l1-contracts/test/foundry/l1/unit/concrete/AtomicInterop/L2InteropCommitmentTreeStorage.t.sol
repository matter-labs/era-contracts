// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Locks the L2InteropCommitmentTree storage ABI the ZKsync OS bootloader depends on:
/// the current IMT root is cached at **fixed slot 0** (`_currentRoot`) and updated on every root
/// change. The bootloader reads exactly this slot at every batch boundary to commit the batch
/// begin/end IMT snapshots into the chain batch root, so any layout drift here is a consensus
/// break — these tests must never be "fixed" to accommodate one without a matching bootloader
/// change.
contract L2InteropCommitmentTreeStorageTest is Test {
    /// @dev The bootloader's hardcoded storage slot for the cached root.
    bytes32 internal constant CURRENT_ROOT_SLOT = bytes32(0);

    L2InteropCommitmentTree internal tree;

    function setUp() public {
        tree = new L2InteropCommitmentTree();
    }

    /// @notice An uninitialized (or absent) tree reads as zero — the same value the bootloader
    /// sees on chains without the atomic stack deployed.
    function test_uninitializedTree_slotZeroIsZero() public view {
        assertEq(vm.load(address(tree), CURRENT_ROOT_SLOT), bytes32(0));
    }

    /// @notice After `initialize`, slot 0 holds the seeded root and matches `root()`.
    function test_initialize_cachesSeedRootAtSlotZero() public {
        tree.initialize();

        bytes32 cached = vm.load(address(tree), CURRENT_ROOT_SLOT);
        assertTrue(cached != bytes32(0));
        assertEq(cached, tree.root());
    }

    /// @notice The freshly seeded tree's root equals `ChainBatchRootTree.EMPTY_IMT_ROOT` — the
    /// constant the settlement layer bakes into the genesis chain batch root it seeds for every
    /// registered chain (see `MessageRootBase._addNewChain`). If the seeding or the leaf hashing
    /// ever changes, this cross-check must be updated together with a matching bootloader change.
    function test_initialize_seedRootMatchesEmptyImtRootConstant() public {
        tree.initialize();
        assertEq(tree.root(), ChainBatchRootTree.EMPTY_IMT_ROOT);
    }

    /// @notice Every insert refreshes the slot-0 cache to the engine's new root.
    function test_insert_updatesSlotZeroCache() public {
        tree.initialize();
        bytes32 seedRoot = vm.load(address(tree), CURRENT_ROOT_SLOT);

        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (, bytes32 newRoot) = tree.insert(uint256(keccak256("commit-value-1")), 0);

        bytes32 cached = vm.load(address(tree), CURRENT_ROOT_SLOT);
        assertTrue(cached != seedRoot);
        assertEq(cached, newRoot);
        assertEq(cached, tree.root());

        // A second insert (low nullifier resolved by the engine's linked-list walk) moves it again.
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (, bytes32 newerRoot) = tree.insert(uint256(keccak256("commit-value-2")), 0);
        assertEq(vm.load(address(tree), CURRENT_ROOT_SLOT), newerRoot);
    }
}
