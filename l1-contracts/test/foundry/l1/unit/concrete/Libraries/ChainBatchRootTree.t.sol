// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";

/// @notice Unit tests for the ChainBatchRootTree library. The tree must mirror the zksync-os
/// bootloader's `compute_chain_batch_root` (a fixed height-3, 8-leaf keccak tree with leaves
/// 4..7 reserved zero) bit-for-bit — these tests lock the hardcoded constant and the compute
/// function against an independent naive recomputation, matching the Rust-side unit tests.
contract ChainBatchRootTreeTest is Test {
    function _node(bytes32 _left, bytes32 _right) internal pure returns (bytes32) {
        return keccak256(bytes.concat(_left, _right));
    }

    /// @notice Locks `RESERVED_SUBTREE_NODE` against its definition: the root of the all-zero
    /// height-2 subtree spanning reserved leaves 4..7.
    function test_reservedSubtreeNode_matchesRecomputation() public pure {
        bytes32 z = bytes32(0);
        bytes32 z1 = keccak256(bytes.concat(z, z));
        bytes32 z2 = keccak256(bytes.concat(z1, z1));
        assertEq(ChainBatchRootTree.RESERVED_SUBTREE_NODE, z2);
    }

    /// @notice `compute` must equal an independent naive recomputation of the full 8-leaf tree
    /// (mirrors the Rust `chain_batch_root_is_height3_merkle` test).
    function test_compute_matchesNaiveHeight3Merkle() public pure {
        bytes32 a = bytes32(uint256(0x0101010101010101010101010101010101010101010101010101010101010101));
        bytes32 b = bytes32(uint256(0x0202020202020202020202020202020202020202020202020202020202020202));
        bytes32 c = bytes32(uint256(0x0303030303030303030303030303030303030303030303030303030303030303));
        bytes32 d = bytes32(uint256(0x0404040404040404040404040404040404040404040404040404040404040404));
        bytes32 z = bytes32(0);

        bytes32[4] memory level1 = [_node(a, b), _node(c, d), _node(z, z), _node(z, z)];
        bytes32[2] memory level2 = [_node(level1[0], level1[1]), _node(level1[2], level1[3])];
        bytes32 expected = _node(level2[0], level2[1]);

        assertEq(ChainBatchRootTree.compute(a, b, c, d), expected);
    }

    /// @notice Fuzz: `compute` equals the naive recomputation for arbitrary live leaves.
    function testFuzz_compute_matchesNaiveHeight3Merkle(
        bytes32 _logsRoot,
        bytes32 _multichainRoot,
        bytes32 _imtRootBegin,
        bytes32 _imtRootEnd
    ) public pure {
        bytes32 z = bytes32(0);
        bytes32 expected = _node(
            _node(_node(_logsRoot, _multichainRoot), _node(_imtRootBegin, _imtRootEnd)),
            _node(_node(z, z), _node(z, z))
        );
        assertEq(ChainBatchRootTree.compute(_logsRoot, _multichainRoot, _imtRootBegin, _imtRootEnd), expected);
    }

    /// @notice An all-zero input (empty batch on a chain with no atomic tree) is well defined and
    /// non-trivial (mirrors the Rust `chain_batch_root_all_zero_is_deterministic` test).
    function test_compute_allZeroIsNonZero() public pure {
        bytes32 z = bytes32(0);
        assertTrue(ChainBatchRootTree.compute(z, z, z, z) != bytes32(0));
    }

    /// @notice The IMT leaves sit exactly `TREE_DEPTH` hops below the root at the documented
    /// indices: recomputing the root from leaf 2 / leaf 3 with their sibling paths must succeed.
    /// This is the property `AtomicInteropProof._authenticateRoot` relies on when it fixes the
    /// leaf mask and proof depth.
    function test_imtLeafPaths_reconstructRoot() public pure {
        bytes32 logsRoot = keccak256("logs");
        bytes32 multichainRoot = keccak256("multichain");
        bytes32 imtBegin = keccak256("imt-begin");
        bytes32 imtEnd = keccak256("imt-end");

        bytes32 root = ChainBatchRootTree.compute(logsRoot, multichainRoot, imtBegin, imtEnd);

        // Path for leaf 2 (imtBegin): sibling leaf 3, then node(leaf0,leaf1), then the reserved subtree.
        assertEq(ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX, 2);
        bytes32 up = _node(imtBegin, imtEnd);
        up = _node(_node(logsRoot, multichainRoot), up);
        assertEq(_node(up, ChainBatchRootTree.RESERVED_SUBTREE_NODE), root);

        // Path for leaf 3 (imtEnd): sibling leaf 2, then the same upper hops.
        assertEq(ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX, 3);
        up = _node(imtBegin, imtEnd);
        up = _node(_node(logsRoot, multichainRoot), up);
        assertEq(_node(up, ChainBatchRootTree.RESERVED_SUBTREE_NODE), root);

        assertEq(ChainBatchRootTree.TREE_DEPTH, 3);
    }
}
