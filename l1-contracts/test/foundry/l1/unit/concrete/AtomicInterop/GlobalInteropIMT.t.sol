// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {GlobalInteropIMT} from "contracts/atomic-interop/GlobalInteropIMT.sol";
import {
    GlobalImtNonConsecutiveBatch,
    GlobalImtZeroBridgehub,
    GlobalImtZeroRoot
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    AtomicInteropTestUtils,
    FullMerkleWrapper,
    MerkleCalldataWrapper,
    MockBridgehub
} from "./AtomicInteropTestUtils.sol";

/// @notice Unit tests for the L1 GlobalInteropIMT registry. `submitChainRoot` is a TEMPORARY
/// permissionless stub (anyone may submit), so these tests submit from arbitrary callers; the
/// per-chain "zk chain flow" (registration + in-place leaf updates) and the append-only history tree
/// are exercised, as is the preserved `chainDiamond` lookup used to re-enable access control.
contract GlobalInteropIMTTest is Test {
    GlobalInteropIMT internal registry;
    MockBridgehub internal bridgehub;
    MerkleCalldataWrapper internal merkleWrapper;

    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;

    address internal diamondA = makeAddr("diamondA");
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        bridgehub = new MockBridgehub();
        bridgehub.setZKChain(CHAIN_A, diamondA);
        registry = new GlobalInteropIMT(address(bridgehub));
        merkleWrapper = new MerkleCalldataWrapper();
    }

    function test_constructor_revertsOnZeroBridgehub() public {
        vm.expectRevert(GlobalImtZeroBridgehub.selector);
        new GlobalInteropIMT(address(0));
    }

    function test_chainDiamond_resolvesViaBridgehub() public view {
        // The "zk chain flow" is preserved so the access check can be re-enabled trivially.
        assertEq(registry.chainDiamond(CHAIN_A), diamondA);
        assertEq(registry.bridgehub(), address(bridgehub));
    }

    function test_submitChainRoot_isPermissionless() public {
        // Anyone may submit any chain's root (temporary stub).
        vm.prank(anyone);
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
        assertEq(registry.chainRootOf(CHAIN_A), keccak256("A"));

        vm.prank(anyone);
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"));
        assertEq(registry.chainRootOf(CHAIN_B), keccak256("B"));
    }

    function test_submitChainRoot_registersAndUpdatesInPlace() public {
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A1"));
        assertTrue(registry.isChainRegistered(CHAIN_A));
        assertEq(registry.leafIndexOf(CHAIN_A), 0);
        assertEq(registry.chainRootOf(CHAIN_A), keccak256("A1"));
        assertEq(registry.currentBatchNumber(CHAIN_A), 1);
        assertEq(registry.chainLeafCount(), 1);

        bytes32 globalBefore = registry.globalRoot();
        registry.submitChainRoot(CHAIN_A, 2, keccak256("A2"));
        assertEq(registry.leafIndexOf(CHAIN_A), 0, "leaf index unchanged on update");
        assertEq(registry.chainRootOf(CHAIN_A), keccak256("A2"));
        assertEq(registry.currentBatchNumber(CHAIN_A), 2);
        assertEq(registry.chainLeafCount(), 1);
        assertTrue(registry.globalRoot() != globalBefore);
    }

    function test_submitChainRoot_twoChains_globalProofValid() public {
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
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

        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
        bytes32 g1 = registry.globalRoot();
        assertEq(registry.historyLeafCount(), 1);
        assertTrue(registry.historyRoot() != historyBefore, "history root advanced");
        assertEq(registry.historyBlockOfRoot(g1), block.number);

        bytes32 historyAfter1 = registry.historyRoot();
        vm.roll(block.number + 1);
        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"));
        assertEq(registry.historyLeafCount(), 2);
        assertTrue(registry.historyRoot() != historyAfter1);
    }

    function test_submitChainRoot_recordsHistoryPerBlock() public {
        registry.submitChainRoot(CHAIN_A, 1, keccak256("A"));
        assertEq(registry.historyLength(), 1);
        assertEq(registry.historyBlockAt(0), block.number);
        assertEq(registry.globalRootAtBlock(block.number), registry.globalRoot());
        assertEq(registry.timestampAtBlock(block.number), block.timestamp);

        registry.submitChainRoot(CHAIN_B, 1, keccak256("B"));
        assertEq(registry.historyLength(), 1, "same block, no new history entry");

        vm.roll(block.number + 5);
        vm.warp(block.timestamp + 100);
        registry.submitChainRoot(CHAIN_A, 2, keccak256("A2"));
        assertEq(registry.historyLength(), 2);
        assertEq(registry.historyBlockAt(1), block.number);
    }

    function test_submitChainRoot_revertsOnZeroRoot() public {
        vm.expectRevert(GlobalImtZeroRoot.selector);
        registry.submitChainRoot(CHAIN_A, 1, bytes32(0));
    }

    function test_submitChainRoot_requiresStrictlyConsecutiveBatches() public {
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
    }
}
