// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {
    CommitmentTreeAlreadyInitialized,
    CommitmentTreeNotAppender,
    CommitmentTreeZeroAppender
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {AtomicInteropTestUtils, FullMerkleWrapper, MerkleCalldataWrapper} from "./AtomicInteropTestUtils.sol";

contract L2InteropCommitmentTreeTest is Test {
    L2InteropCommitmentTree internal tree;
    MerkleCalldataWrapper internal merkleWrapper;

    address internal escrow = makeAddr("escrow");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        tree = new L2InteropCommitmentTree();
        merkleWrapper = new MerkleCalldataWrapper();
        tree.initialize(escrow);
    }

    function test_initialize_setsAppenderOnce() public {
        assertEq(tree.appender(), escrow);
        assertEq(tree.leafCount(), 0);

        vm.expectRevert(CommitmentTreeAlreadyInitialized.selector);
        tree.initialize(escrow);
    }

    function test_initialize_revertsOnZeroAppender() public {
        L2InteropCommitmentTree fresh = new L2InteropCommitmentTree();
        vm.expectRevert(CommitmentTreeZeroAppender.selector);
        fresh.initialize(address(0));
    }

    function test_appendCommitment_onlyAppender() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CommitmentTreeNotAppender.selector, stranger));
        tree.appendCommitment(keccak256("leaf"));
    }

    function test_appendCommitment_buildsTreeAndPathsVerify() public {
        // Append several leaves and check each leaf's inclusion path against the final root.
        uint256 n = 5;
        bytes32[] memory leaves = new bytes32[](n);
        FullMerkleWrapper mirror = new FullMerkleWrapper();

        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = keccak256(abi.encodePacked("leaf", i));
            vm.prank(escrow);
            (uint256 index, bytes32 newRoot) = tree.appendCommitment(leaves[i]);
            assertEq(index, i);
            mirror.push(leaves[i]);
            // The contract's incremental root must match the FullMerkle reconstruction at every step.
            assertEq(newRoot, mirror.root(), "root mismatch after append");
        }
        assertEq(tree.leafCount(), n);
        assertEq(tree.root(), mirror.root());

        bytes32 finalRoot = tree.root();
        for (uint256 i = 0; i < n; ++i) {
            bytes32[] memory path = mirror.path(i);
            assertEq(merkleWrapper.calcRoot(path, i, leaves[i]), finalRoot, "inclusion path must verify");
        }
    }
}
