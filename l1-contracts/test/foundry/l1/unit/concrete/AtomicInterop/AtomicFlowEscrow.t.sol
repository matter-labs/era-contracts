// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {GlobalInteropIMT} from "contracts/atomic-interop/GlobalInteropIMT.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {L2GlobalInteropRootImporter} from "contracts/atomic-interop/L2GlobalInteropRootImporter.sol";
import {AtomicFlowEscrow} from "contracts/atomic-interop/AtomicFlowEscrow.sol";
import {
    FlowLeg,
    IndexedLeaf,
    PartState,
    ImtInclusionProof,
    ImtNonInclusionProof
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    EscrowFlowIdMismatch,
    EscrowLegNotOnThisChain,
    EscrowPartNotUnset,
    EscrowPayerMismatch,
    EscrowLegZeroAmount
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {ProofDeadlineExceeded, ProofLowNullifierNotAbove} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {AtomicInteropTestUtils, FullMerkleWrapper, IndexedImtProver} from "./AtomicInteropTestUtils.sol";

/// @notice End-to-end tests for the L1-free atomic interop flow with an Indexed Merkle Tree per
/// chain. Two "chains" are simulated within one EVM via `vm.chainId`. The flow finalizes only when
/// both legs are proven committed in time (O(log n) inclusion), and refunds when a leg is proven
/// absent across the deadline boundary (O(log n) low-nullifier non-inclusion) — no L1 coordinator.
contract AtomicFlowEscrowTest is Test {
    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;
    uint64 internal constant DEADLINE = 2000;

    GlobalInteropIMT internal registry;
    IndexedImtProver internal prover;
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal supplier = makeAddr("supplier");

    L2InteropCommitmentTree internal treeA;
    L2InteropCommitmentTree internal treeB;
    L2GlobalInteropRootImporter internal importerA;
    L2GlobalInteropRootImporter internal importerB;
    AtomicFlowEscrow internal escrowA;
    AtomicFlowEscrow internal escrowB;
    TestnetERC20Token internal tokenA;
    TestnetERC20Token internal tokenB;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function setUp() public {
        registry = new GlobalInteropIMT(owner);
        prover = new IndexedImtProver();
        vm.prank(owner);
        registry.setGlobalSubmitter(operator, true);

        (treeA, importerA, escrowA) = _deployStack();
        (treeB, importerB, escrowB) = _deployStack();

        tokenA = new TestnetERC20Token("TokenA", "TKA", 18);
        tokenB = new TestnetERC20Token("TokenB", "TKB", 18);
        tokenA.mint(alice, 1_000);
        tokenB.mint(carol, 1_000);
    }

    function _deployStack()
        internal
        returns (L2InteropCommitmentTree tree, L2GlobalInteropRootImporter importer, AtomicFlowEscrow escrow)
    {
        tree = new L2InteropCommitmentTree();
        importer = new L2GlobalInteropRootImporter();
        escrow = new AtomicFlowEscrow();
        tree.initialize(address(escrow));
        importer.initialize(supplier);
        escrow.initialize(address(tree), address(importer));
    }

    // ── Happy path ──────────────────────────────────────────────────────────────────────

    function test_finalize_happyPath_bothLegsSettle() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        FlowLeg memory legB = FlowLeg(CHAIN_B, address(tokenB), 50, carol, dave);
        (FlowLeg[] memory legs, bytes32[] memory specHashes) = _sorted(legA, legB);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        _commit(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, legA);
        _commit(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, legB);

        _exposeAndImport(100, 1500);

        ImtInclusionProof[] memory proofs = new ImtInclusionProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            proofs[i] = _inclusion(legs[i], flowId, 100);
        }

        vm.chainId(CHAIN_A);
        escrowA.finalize(flowId, legs, _chainIds(), DEADLINE, proofs);
        vm.chainId(CHAIN_B);
        escrowB.finalize(flowId, legs, _chainIds(), DEADLINE, proofs);

        assertEq(tokenA.balanceOf(bob), 100, "bob received");
        assertEq(tokenA.balanceOf(address(escrowA)), 0, "escrowA drained");
        assertEq(tokenB.balanceOf(dave), 50, "dave received");
        assertTrue(escrowA.partState(flowId, AtomicInteropTestUtils.specHashOf(legA)) == PartState.Finalized);
        assertTrue(escrowB.partState(flowId, AtomicInteropTestUtils.specHashOf(legB)) == PartState.Finalized);
    }

    function test_finalize_revertsWhenImportedAfterDeadline() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        FlowLeg memory legB = FlowLeg(CHAIN_B, address(tokenB), 50, carol, dave);
        (FlowLeg[] memory legs, bytes32[] memory specHashes) = _sorted(legA, legB);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        _commit(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, legA);
        _commit(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, legB);
        _exposeAndImport(100, 5000); // timestamp AFTER deadline

        ImtInclusionProof[] memory proofs = new ImtInclusionProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            proofs[i] = _inclusion(legs[i], flowId, 100);
        }

        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, 5000, DEADLINE));
        escrowA.finalize(flowId, legs, _chainIds(), DEADLINE, proofs);
    }

    function test_finalize_revertsOnFlowIdMismatch() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        FlowLeg memory legB = FlowLeg(CHAIN_B, address(tokenB), 50, carol, dave);
        (FlowLeg[] memory legs, bytes32[] memory specHashes) = _sorted(legA, legB);
        bytes32 realFlowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        _commit(escrowA, tokenA, treeA, CHAIN_A, alice, realFlowId, legA);
        _commit(escrowB, tokenB, treeB, CHAIN_B, carol, realFlowId, legB);
        _exposeAndImport(100, 1500);

        ImtInclusionProof[] memory proofs = new ImtInclusionProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            proofs[i] = _inclusion(legs[i], realFlowId, 100);
        }

        bytes32 wrongFlowId = keccak256("wrong");
        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(EscrowFlowIdMismatch.selector, wrongFlowId, realFlowId));
        escrowA.finalize(wrongFlowId, legs, _chainIds(), DEADLINE, proofs);
    }

    // ── Timeout / refund path ───────────────────────────────────────────────────────────

    function test_refund_whenLegMissingAcrossDeadline() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        FlowLeg memory legB = FlowLeg(CHAIN_B, address(tokenB), 50, carol, dave);
        (FlowLeg[] memory legs, bytes32[] memory specHashes) = _sorted(legA, legB);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        // A commits; B never does (its IMT holds only the head leaf, which is the low nullifier for
        // any absent value — so non-inclusion is a single-leaf proof).
        _commit(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, legA);
        _exposeAndImportForRefund();

        ImtNonInclusionProof memory proof = _nonInclusion(treeB, CHAIN_B, flowId, legB);

        uint256 aliceBefore = tokenA.balanceOf(alice);
        vm.chainId(CHAIN_A);
        escrowA.refund(flowId, legs, _chainIds(), DEADLINE, _missingIdx(legs), proof);

        assertEq(tokenA.balanceOf(alice), aliceBefore + 100, "alice refunded");
        assertTrue(escrowA.partState(flowId, AtomicInteropTestUtils.specHashOf(legA)) == PartState.Refunded);
    }

    function test_refund_revertsIfLegActuallyPresent() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        FlowLeg memory legB = FlowLeg(CHAIN_B, address(tokenB), 50, carol, dave);
        (FlowLeg[] memory legs, bytes32[] memory specHashes) = _sorted(legA, legB);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        // Both committed -> legB IS present. legB is the only real leaf on B, so the head now points
        // at legB's value; using the head as a "low nullifier" fails the upper-bracket check.
        _commit(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, legA);
        _commit(escrowB, tokenB, treeB, CHAIN_B, carol, flowId, legB);
        _exposeAndImportForRefund();

        uint256 legBValue = AtomicInteropTestUtils.commitValue(flowId, AtomicInteropTestUtils.specHashOf(legB));
        // Forge the proof with the (real) head leaf as the claimed low nullifier.
        FullMerkleWrapper mirror = prover.mirror(treeB);
        ImtNonInclusionProof memory proof = ImtNonInclusionProof({
            chainId: CHAIN_B,
            chainImtRoot: treeB.root(),
            lowLeaf: treeB.leafAt(0),
            lowLeafIndex: 0,
            imtProof: mirror.path(0),
            globalLeafIndex: registry.leafIndexOf(CHAIN_B),
            l1BlockNumberBeforeDeadline: 100,
            globalProofG1: registry.merklePathForChain(CHAIN_B),
            l1BlockNumberAfterDeadline: 200,
            globalProofG2: registry.merklePathForChain(CHAIN_B)
        });

        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(ProofLowNullifierNotAbove.selector, legBValue, legBValue));
        escrowA.refund(flowId, legs, _chainIds(), DEADLINE, _missingIdx(legs), proof);
    }

    // ── commitPart edge cases ───────────────────────────────────────────────────────────

    function test_commitPart_revertsOnWrongChain() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        vm.chainId(CHAIN_B);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EscrowLegNotOnThisChain.selector, CHAIN_A));
        escrowA.commitPart(keccak256("f"), legA, 0);
    }

    function test_commitPart_revertsOnPayerMismatch() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        vm.chainId(CHAIN_A);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EscrowPayerMismatch.selector, bob, alice));
        escrowA.commitPart(keccak256("f"), legA, 0);
    }

    function test_commitPart_revertsOnZeroAmount() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 0, alice, bob);
        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.expectRevert(EscrowLegZeroAmount.selector);
        escrowA.commitPart(keccak256("f"), legA, 0);
    }

    function test_commitPart_revertsOnDoubleCommit() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        bytes32 flowId = keccak256("f");
        _commit(escrowA, tokenA, treeA, CHAIN_A, alice, flowId, legA);
        bytes32 specHash = AtomicInteropTestUtils.specHashOf(legA);

        vm.chainId(CHAIN_A);
        vm.prank(alice);
        tokenA.approve(address(escrowA), 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EscrowPartNotUnset.selector, specHash, PartState.Committed));
        escrowA.commitPart(flowId, legA, 0);
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────

    function _chainIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = CHAIN_A; // CHAIN_A < CHAIN_B
        ids[1] = CHAIN_B;
    }

    function _missingIdx(FlowLeg[] memory _legs) internal pure returns (uint256) {
        return _legs[0].chainId == CHAIN_B ? 0 : 1;
    }

    function _sorted(
        FlowLeg memory _legA,
        FlowLeg memory _legB
    ) internal pure returns (FlowLeg[] memory legs, bytes32[] memory specHashes) {
        bytes32 hA = AtomicInteropTestUtils.specHashOf(_legA);
        bytes32 hB = AtomicInteropTestUtils.specHashOf(_legB);
        legs = new FlowLeg[](2);
        specHashes = new bytes32[](2);
        if (hA < hB) {
            (legs[0], legs[1], specHashes[0], specHashes[1]) = (_legA, _legB, hA, hB);
        } else {
            (legs[0], legs[1], specHashes[0], specHashes[1]) = (_legB, _legA, hB, hA);
        }
    }

    /// @dev Compute the leg's commit value, find its low-nullifier in the chain's IMT, and commit.
    function _commit(
        AtomicFlowEscrow _escrow,
        TestnetERC20Token _token,
        IL2InteropCommitmentTree _tree,
        uint256 _chainId,
        address _payer,
        bytes32 _flowId,
        FlowLeg memory _leg
    ) internal {
        uint256 value = AtomicInteropTestUtils.commitValue(_flowId, AtomicInteropTestUtils.specHashOf(_leg));
        uint256 lowNull = prover.lowNullifierIndex(_tree, value);
        vm.chainId(_chainId);
        vm.prank(_payer);
        _token.approve(address(_escrow), _leg.amount);
        vm.prank(_payer);
        _escrow.commitPart(_flowId, _leg, lowNull);
    }

    /// @dev Submit both chains' roots and import the resulting global root into both importers.
    function _exposeAndImport(uint256 _l1Block, uint256 _timestamp) internal {
        bytes32 rootA = treeA.root();
        bytes32 rootB = treeB.root();
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_A, 1, rootA, bytes32(0));
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_B, 1, rootB, bytes32(0));
        bytes32 gRoot = registry.globalRoot();
        vm.prank(supplier);
        importerA.importGlobalRoot(_l1Block, _timestamp, gRoot);
        vm.prank(supplier);
        importerB.importGlobalRoot(_l1Block, _timestamp, gRoot);
    }

    /// @dev Import the same global root before AND after the deadline (chain B unchanged across it).
    function _exposeAndImportForRefund() internal {
        bytes32 rootA = treeA.root();
        bytes32 rootB = treeB.root();
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_A, 1, rootA, bytes32(0));
        vm.prank(operator);
        registry.submitChainRoot(CHAIN_B, 1, rootB, bytes32(0));
        bytes32 gRoot = registry.globalRoot();
        vm.prank(supplier);
        importerA.importGlobalRoot(100, 1500, gRoot); // before deadline
        vm.prank(supplier);
        importerA.importGlobalRoot(200, 5000, gRoot); // after deadline
    }

    /// @dev Build an inclusion proof for a committed leg.
    function _inclusion(
        FlowLeg memory _leg,
        bytes32 _flowId,
        uint256 _l1Block
    ) internal returns (ImtInclusionProof memory) {
        IL2InteropCommitmentTree tree = _leg.chainId == CHAIN_A ? treeA : treeB;
        uint256 value = AtomicInteropTestUtils.commitValue(_flowId, AtomicInteropTestUtils.specHashOf(_leg));
        uint256 idx = prover.indexOfValue(tree, value);
        FullMerkleWrapper mirror = prover.mirror(tree);
        return
            ImtInclusionProof({
                chainId: _leg.chainId,
                chainImtRoot: tree.root(),
                leaf: tree.leafAt(idx),
                imtLeafIndex: idx,
                imtProof: mirror.path(idx),
                globalLeafIndex: registry.leafIndexOf(_leg.chainId),
                globalProof: registry.merklePathForChain(_leg.chainId),
                l1BlockNumber: _l1Block
            });
    }

    /// @dev Build a (valid) non-inclusion proof for an absent leg, bracketing the deadline.
    function _nonInclusion(
        IL2InteropCommitmentTree _tree,
        uint256 _chainId,
        bytes32 _flowId,
        FlowLeg memory _leg
    ) internal returns (ImtNonInclusionProof memory) {
        uint256 value = AtomicInteropTestUtils.commitValue(_flowId, AtomicInteropTestUtils.specHashOf(_leg));
        uint256 lowIdx = prover.lowNullifierIndex(_tree, value);
        FullMerkleWrapper mirror = prover.mirror(_tree);
        return
            ImtNonInclusionProof({
                chainId: _chainId,
                chainImtRoot: _tree.root(),
                lowLeaf: _tree.leafAt(lowIdx),
                lowLeafIndex: lowIdx,
                imtProof: mirror.path(lowIdx),
                globalLeafIndex: registry.leafIndexOf(_chainId),
                l1BlockNumberBeforeDeadline: 100,
                globalProofG1: registry.merklePathForChain(_chainId),
                l1BlockNumberAfterDeadline: 200,
                globalProofG2: registry.merklePathForChain(_chainId)
            });
    }
}
