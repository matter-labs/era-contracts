// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {GlobalInteropIMT} from "contracts/atomic-interop/GlobalInteropIMT.sol";
import {
    GlobalImtNonConsecutiveBatch,
    GlobalImtNotOwner,
    GlobalImtNotSubmitter,
    GlobalImtZeroBridgehub,
    GlobalImtZeroRoot,
    GlobalImtZeroSubmitter
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    AtomicInteropTestUtils,
    FullMerkleWrapper,
    MerkleCalldataWrapper,
    MockBridgehub
} from "./AtomicInteropTestUtils.sol";

contract GlobalInteropIMTTest is Test {
    GlobalInteropIMT internal registry;
    MockBridgehub internal bridgehub;
    MerkleCalldataWrapper internal merkleWrapper;

    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;

    // Diamond proxies (the authorized submitters) per chain.
    address internal diamondA = makeAddr("diamondA");
    address internal diamondB = makeAddr("diamondB");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        bridgehub = new MockBridgehub();
        bridgehub.setZKChain(CHAIN_A, diamondA);
        bridgehub.setZKChain(CHAIN_B, diamondB);
        registry = new GlobalInteropIMT(address(bridgehub));
        merkleWrapper = new MerkleCalldataWrapper();
    }

    function test_constructor_revertsOnZeroBridgehub() public {
        vm.expectRevert(GlobalImtZeroBridgehub.selector);
        new GlobalInteropIMT(address(0));
    }

    function test_submitChainRoot_registersAndUpdatesInPlace() public {
        bytes32 rootA1 = keccak256("A1");

        vm.prank(diamondA);
        registry.submitChainRoot(CHAIN_A, 1, rootA1);

        assertTrue(registry.isChainRegistered(CHAIN_A));
        assertEq(registry.leafIndexOf(CHAIN_A), 0);
        assertEq(registry.chainRootOf(CHAIN_A), rootA1);
        assertEq(registry.currentBatchNumber(CHAIN_A), 1);
        assertEq(registry.chainLeafCount(), 1);

        bytes32 globalBefore = registry.globalRoot();
        vm.prank(diamondA);
        registry.submitChainRoot(CHAIN_A, 2, keccak256("A2"));

        assertEq(registry.leafIndexOf(CHAIN_A), 0, "leaf index unchanged on update");
        assertEq(registry.chainRootOf(CHAIN_A), keccak256("A2"));
        assertEq(registry.currentBatchNumber(CHAIN_A), 2);
        assertEq(registry.chainLeafCount(), 1);
        assertTrue(registry.globalRoot() != globalBefore);
    }

    function test_submitChainRoot_twoChains_globalProofValid() public {
        vm.prank(diamondA);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
        vm.prank(diamondB);
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"));

        assertEq(registry.leafIndexOf(CHAIN_A), 0);
        assertEq(registry.leafIndexOf(CHAIN_B), 1);

        bytes32 globalRoot = registry.globalRoot();
        bytes32 leafA = AtomicInteropTestUtils.globalLeaf(CHAIN_A, keccak256("A"));
        assertEq(merkleWrapper.calcRoot(registry.merklePathForChain(CHAIN_A), 0, leafA), globalRoot, "chain A proof");
        bytes32 leafB = AtomicInteropTestUtils.globalLeaf(CHAIN_B, keccak256("B"));
        assertEq(merkleWrapper.calcRoot(registry.merklePathForChain(CHAIN_B), 1, leafB), globalRoot, "chain B proof");

        FullMerkleWrapper independent = new FullMerkleWrapper();
        independent.push(leafA);
        independent.push(leafB);
        assertEq(independent.root(), globalRoot, "matches independent FullMerkle");
    }

    function test_submitChainRoot_appendsHistoryTree() public {
        bytes32 historyBefore = registry.historyRoot();
        assertEq(registry.historyLeafCount(), 0);

        vm.prank(diamondA);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
        bytes32 g1 = registry.globalRoot();

        assertEq(registry.historyLeafCount(), 1);
        assertTrue(registry.historyRoot() != historyBefore, "history root advanced");
        assertEq(registry.historyBlockOfRoot(g1), block.number);

        bytes32 historyAfter1 = registry.historyRoot();
        vm.roll(block.number + 1);
        vm.prank(diamondB);
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"));
        assertEq(registry.historyLeafCount(), 2);
        assertTrue(registry.historyRoot() != historyAfter1);
    }

    function test_submitChainRoot_recordsHistoryPerBlock() public {
        vm.prank(diamondA);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
        assertEq(registry.historyLength(), 1);
        assertEq(registry.historyBlockAt(0), block.number);
        assertEq(registry.globalRootAtBlock(block.number), registry.globalRoot());
        assertEq(registry.timestampAtBlock(block.number), block.timestamp);

        vm.prank(diamondB);
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"));
        assertEq(registry.historyLength(), 1, "same block, no new history entry");

        vm.roll(block.number + 5);
        vm.warp(block.timestamp + 100);
        vm.prank(diamondA);
        registry.submitChainRoot(CHAIN_A, 2, keccak256("A2"));
        assertEq(registry.historyLength(), 2);
        assertEq(registry.historyBlockAt(1), block.number);
    }

    function test_submitChainRoot_revertsForNonSubmitter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNotSubmitter.selector, stranger, CHAIN_A));
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));

        // Even the *other* chain's diamond cannot submit for CHAIN_A.
        vm.prank(diamondB);
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNotSubmitter.selector, diamondB, CHAIN_A));
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
    }

    function test_globalSubmitter_canSubmitForAnyChain() public {
        address relayer = makeAddr("relayer");
        // The deployer (this test) is the owner and authorizes the temporary global submitter.
        registry.setGlobalSubmitter(relayer, true);
        assertTrue(registry.isGlobalSubmitter(relayer));

        // The relayer can submit for any chain, bypassing the Bridgehub diamond check.
        vm.prank(relayer);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
        vm.prank(relayer);
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"));
        assertEq(registry.chainRootOf(CHAIN_A), keccak256("A"));
        assertEq(registry.chainRootOf(CHAIN_B), keccak256("B"));

        // Deauthorizing revokes the ability.
        registry.setGlobalSubmitter(relayer, false);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNotSubmitter.selector, relayer, CHAIN_A));
        registry.submitChainRoot(CHAIN_A, 2, keccak256("A2"));
    }

    function test_setGlobalSubmitter_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNotOwner.selector, stranger));
        registry.setGlobalSubmitter(stranger, true);

        vm.expectRevert(GlobalImtZeroSubmitter.selector);
        registry.setGlobalSubmitter(address(0), true);
    }

    function test_submitChainRoot_revertsOnZeroRoot() public {
        vm.prank(diamondA);
        vm.expectRevert(GlobalImtZeroRoot.selector);
        registry.submitChainRoot(CHAIN_A, 1, bytes32(0));
    }

    function test_submitChainRoot_requiresStrictlyConsecutiveBatches() public {
        vm.startPrank(diamondA);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A1"));
        // Re-submitting batch 1 (expected 2).
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNonConsecutiveBatch.selector, CHAIN_A, 2, 1));
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A1b"));
        // Gaps are NOT allowed (expected 2).
        vm.expectRevert(abi.encodeWithSelector(GlobalImtNonConsecutiveBatch.selector, CHAIN_A, 2, 3));
        registry.submitChainRoot(CHAIN_A, 3, keccak256("A3"));
        // The exact next batch works.
        registry.submitChainRoot(CHAIN_A, 2, keccak256("A2"));
        assertEq(registry.currentBatchNumber(CHAIN_A), 2);
        vm.stopPrank();
    }
}
