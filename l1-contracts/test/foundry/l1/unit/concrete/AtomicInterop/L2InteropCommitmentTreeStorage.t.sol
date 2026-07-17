// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Locks the L2InteropCommitmentTree storage ABI the ZKsync OS bootloader depends on:
/// the bootloader reads the engine's root `_imt.tree._nodes[_height][0]` directly (the same scheme
/// it uses for the L2MessageRoot multichain root) — it loads `_height` from slot 0 and derives the
/// `_nodes[_height][0]` slot from the `_nodes` base slot 2. The bootloader reads exactly those slots
/// at every batch boundary to commit the batch begin/end IMT snapshots into the chain batch root, so
/// any layout drift here is a consensus break — these tests must never be "fixed" to accommodate one
/// without a matching bootloader change.
contract L2InteropCommitmentTreeStorageTest is Test {
    /// @dev The bootloader's hardcoded slot of `_imt.tree._height` (the IMT is the first state
    /// variable and `FullMerkle.FullTree` puts `_height` at offset 0).
    bytes32 internal constant TREE_HEIGHT_SLOT = bytes32(0);
    /// @dev The bootloader's hardcoded base slot of `_imt.tree._nodes` (`FullTree` offset 2).
    uint256 internal constant TREE_NODES_SLOT = 2;

    L2InteropCommitmentTree internal tree;

    function setUp() public {
        tree = new L2InteropCommitmentTree();
    }

    /// @dev Mirrors the bootloader's root-slot derivation: `_nodes[height][0]` for a
    /// two-dimensional dynamic array rooted at `TREE_NODES_SLOT`.
    function _rootSlot(uint256 _height) internal pure returns (bytes32) {
        bytes32 nodesHeightSlot = bytes32(uint256(keccak256(abi.encode(TREE_NODES_SLOT))) + _height);
        return keccak256(abi.encode(nodesHeightSlot));
    }

    /// @dev Reads the root exactly the way the bootloader does: height from slot 0, then
    /// `_nodes[height][0]`.
    function _readRootLikeBootloader() internal view returns (bytes32) {
        uint256 height = uint256(vm.load(address(tree), TREE_HEIGHT_SLOT));
        return vm.load(address(tree), _rootSlot(height));
    }

    /// @notice An uninitialized (or absent) tree reads as zero — the same value the bootloader
    /// sees on chains without the atomic stack deployed.
    function test_uninitializedTree_readsAsZero() public view {
        assertEq(_readRootLikeBootloader(), bytes32(0));
    }

    /// @notice After `initialize`, the bootloader's derived slot holds the seeded root and matches
    /// `root()`.
    function test_initL2_bootloaderReadMatchesRoot() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();

        bytes32 read = _readRootLikeBootloader();
        assertTrue(read != bytes32(0));
        assertEq(read, tree.root());
    }

    /// @notice The freshly seeded tree's root equals `ChainBatchRootTree.EMPTY_IMT_ROOT` — the
    /// constant baked into the IMT leaves of `ChainBatchRootTree.genesisChainBatchRoot()`, which
    /// `DiamondInit` stores for a fresh ZKsync OS chain (later pulled into the settlement layer via
    /// `MessageRoot.seedGenesisRoot`). If the seeding or the leaf hashing ever changes, this
    /// cross-check must be updated together with a matching bootloader change.
    function test_initL2_seedRootMatchesEmptyImtRootConstant() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();
        assertEq(tree.root(), ChainBatchRootTree.EMPTY_IMT_ROOT);
    }

    /// @notice Every insert moves the engine root the bootloader reads, including across a height
    /// change (the seeded tree starts at height 0 and grows as leaves are added), which exercises
    /// the height-dependent slot derivation.
    function test_insert_movesBootloaderReadRoot() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();
        bytes32 seedRoot = _readRootLikeBootloader();

        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (, bytes32 newRoot) = tree.insert(uint256(keccak256("commit-value-1")), 0);

        bytes32 read = _readRootLikeBootloader();
        assertTrue(read != seedRoot);
        assertEq(read, newRoot);
        assertEq(read, tree.root());

        // A second insert (low nullifier resolved by the engine's linked-list walk) moves it again.
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (, bytes32 newerRoot) = tree.insert(uint256(keccak256("commit-value-2")), 0);
        assertEq(_readRootLikeBootloader(), newerRoot);
        assertEq(_readRootLikeBootloader(), tree.root());
    }
}
