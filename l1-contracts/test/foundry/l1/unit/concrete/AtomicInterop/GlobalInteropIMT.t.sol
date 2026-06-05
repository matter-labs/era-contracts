// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {GlobalInteropIMT} from "contracts/atomic-interop/GlobalInteropIMT.sol";
import {IGlobalInteropIMT} from "contracts/atomic-interop/IGlobalInteropIMT.sol";
import {
    GlobalImtBatchNotIncreasing,
    GlobalImtNotOwner,
    GlobalImtNotSubmitter,
    GlobalImtZeroOwner,
    GlobalImtZeroRoot,
    GlobalImtZeroSubmitter
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {AtomicInteropTestUtils, FullMerkleWrapper, MerkleCalldataWrapper} from "./AtomicInteropTestUtils.sol";

contract GlobalInteropIMTTest is Test {
    GlobalInteropIMT internal registry;
    MerkleCalldataWrapper internal merkleWrapper;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;

    function setUp() public {
        registry = new GlobalInteropIMT(owner);
        merkleWrapper = new MerkleCalldataWrapper();
        vm.prank(owner);
        registry.setGlobalSubmitter(operator, true);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(GlobalImtZeroOwner.selector);
        new GlobalInteropIMT(address(0));
    }

    function test_submitChainRoot_registersAndUpdatesInPlace() public {
        bytes32 rootA1 = keccak256("A1");
        bytes32 daA1 = keccak256("daA1");

        vm.prank(operator);
        registry.submitChainRoot(CHAIN_A, 1, rootA1, daA1);

        assertTrue(registry.isChainRegistered(CHAIN_A));
        assertEq(registry.leafIndexOf(CHAIN_A), 0);
        assertEq(registry.chainRootOf(CHAIN_A), rootA1);
        assertEq(registry.currentBatchNumber(CHAIN_A), 1);
        assertEq(registry.daCommitmentOf(CHAIN_A, 1), daA1);
        assertEq(registry.chainLeafCount(), 1);

        // Update in place: same leaf index, new root, root advances.
        bytes32 globalBefore = registry.globalRoot();
        bytes32 rootA2 = keccak256("A2");
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_A, 2, rootA2, keccak256("daA2"));

        assertEq(registry.leafIndexOf(CHAIN_A), 0, "leaf index must not change on update");
        assertEq(registry.chainRootOf(CHAIN_A), rootA2);
        assertEq(registry.currentBatchNumber(CHAIN_A), 2);
        assertEq(registry.chainLeafCount(), 1, "no new chain registered");
        assertTrue(registry.globalRoot() != globalBefore, "global root must advance");
    }

    function test_submitChainRoot_twoChains_globalProofValid() public {
        bytes32 rootA = keccak256("A");
        bytes32 rootB = keccak256("B");

        vm.startPrank(operator);
        registry.submitChainRoot(CHAIN_A, 1, rootA, bytes32(0));
        registry.submitChainRoot(CHAIN_B, 1, rootB, bytes32(0));
        vm.stopPrank();

        assertEq(registry.leafIndexOf(CHAIN_A), 0);
        assertEq(registry.leafIndexOf(CHAIN_B), 1);

        bytes32 globalRoot = registry.globalRoot();

        // The on-chain Merkle path for each chain must verify against the global root.
        bytes32 leafA = AtomicInteropTestUtils.globalLeaf(CHAIN_A, rootA);
        bytes32[] memory pathA = registry.merklePathForChain(CHAIN_A);
        assertEq(merkleWrapper.calcRoot(pathA, 0, leafA), globalRoot, "chain A global proof");

        bytes32 leafB = AtomicInteropTestUtils.globalLeaf(CHAIN_B, rootB);
        bytes32[] memory pathB = registry.merklePathForChain(CHAIN_B);
        assertEq(merkleWrapper.calcRoot(pathB, 1, leafB), globalRoot, "chain B global proof");

        // Independently rebuild the global root with a FullMerkle tree.
        FullMerkleWrapper independent = new FullMerkleWrapper();
        independent.push(leafA);
        independent.push(leafB);
        assertEq(independent.root(), globalRoot, "global root matches independent FullMerkle");
    }

    function test_submitChainRoot_recordsHistoryPerBlock() public {
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"), bytes32(0));
        assertEq(registry.historyLength(), 1);
        assertEq(registry.historyBlockAt(0), block.number);
        assertEq(registry.globalRootAtBlock(block.number), registry.globalRoot());
        assertEq(registry.timestampAtBlock(block.number), block.timestamp);

        // Same block, another submit -> updates same history entry, no new block recorded.
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"), bytes32(0));
        assertEq(registry.historyLength(), 1, "same block must not append a new history entry");
        assertEq(registry.globalRootAtBlock(block.number), registry.globalRoot());

        // New block -> new history entry.
        vm.roll(block.number + 5);
        vm.warp(block.timestamp + 100);
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_A, 2, keccak256("A2"), bytes32(0));
        assertEq(registry.historyLength(), 2);
        assertEq(registry.historyBlockAt(1), block.number);
    }

    function test_submitChainRoot_appendsHistoryTree() public {
        bytes32 historyBefore = registry.historyRoot();
        assertEq(registry.historyLeafCount(), 0);

        vm.prank(operator);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"), bytes32(0));
        bytes32 g1 = registry.globalRoot();

        assertEq(registry.historyLeafCount(), 1, "one snapshot appended");
        assertTrue(registry.historyRoot() != historyBefore, "history root advanced");
        assertEq(registry.historyBlockOfRoot(g1), block.number, "global root mapped to its block");

        // A second submit appends another history leaf and advances the history root.
        bytes32 historyAfter1 = registry.historyRoot();
        vm.roll(block.number + 1);
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"), bytes32(0));

        assertEq(registry.historyLeafCount(), 2);
        assertTrue(registry.historyRoot() != historyAfter1, "history root advanced again");
        assertEq(registry.historyBlockOfRoot(registry.globalRoot()), block.number);
    }

    function test_submitChainRoot_perChainSubmitterAuthorized() public {
        address chainSubmitter = makeAddr("chainSubmitter");
        vm.prank(owner);
        registry.setSubmitter(CHAIN_A, chainSubmitter, true);

        vm.prank(chainSubmitter);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"), bytes32(0));
        assertEq(registry.chainRootOf(CHAIN_A), keccak256("A"));

        // Not authorized for CHAIN_B.
        vm.prank(chainSubmitter);
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNotSubmitter.selector, chainSubmitter, CHAIN_B));
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"), bytes32(0));
    }

    function test_submitChainRoot_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNotSubmitter.selector, stranger, CHAIN_A));
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"), bytes32(0));
    }

    function test_submitChainRoot_revertsOnZeroRoot() public {
        vm.prank(operator);
        vm.expectRevert(GlobalImtZeroRoot.selector);
        registry.submitChainRoot(CHAIN_A, 1, bytes32(0), bytes32(0));
    }

    function test_submitChainRoot_revertsOnNonIncreasingBatch() public {
        vm.startPrank(operator);
        registry.submitChainRoot(CHAIN_A, 5, keccak256("A"), bytes32(0));
        // Same batch number again -> not increasing.
        vm.expectRevert(abi.encodeWithSelector(GlobalImtBatchNotIncreasing.selector, CHAIN_A, 5, 5));
        registry.submitChainRoot(CHAIN_A, 5, keccak256("A2"), bytes32(0));
        // Lower batch number -> not increasing.
        vm.expectRevert(abi.encodeWithSelector(GlobalImtBatchNotIncreasing.selector, CHAIN_A, 5, 3));
        registry.submitChainRoot(CHAIN_A, 3, keccak256("A3"), bytes32(0));
        // Gaps are allowed.
        registry.submitChainRoot(CHAIN_A, 9, keccak256("A9"), bytes32(0));
        assertEq(registry.currentBatchNumber(CHAIN_A), 9);
        vm.stopPrank();
    }

    function test_setSubmitter_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNotOwner.selector, stranger));
        registry.setSubmitter(CHAIN_A, stranger, true);

        vm.prank(owner);
        vm.expectRevert(GlobalImtZeroSubmitter.selector);
        registry.setSubmitter(CHAIN_A, address(0), true);
    }

    function test_setGlobalSubmitter_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNotOwner.selector, stranger));
        registry.setGlobalSubmitter(stranger, true);
    }
}
