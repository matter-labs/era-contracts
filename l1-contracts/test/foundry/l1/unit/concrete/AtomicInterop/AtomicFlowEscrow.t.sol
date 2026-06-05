// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {GlobalInteropIMT} from "contracts/atomic-interop/GlobalInteropIMT.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {L2GlobalInteropRootImporter} from "contracts/atomic-interop/L2GlobalInteropRootImporter.sol";
import {AtomicFlowEscrow} from "contracts/atomic-interop/AtomicFlowEscrow.sol";
import {FlowLeg, PartState, ImtInclusionProof, ImtNonInclusionProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    EscrowFlowIdMismatch,
    EscrowLegNotOnThisChain,
    EscrowPartNotUnset,
    EscrowPayerMismatch,
    EscrowLegZeroAmount
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {ProofDeadlineExceeded, ProofLeafPresent} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {AtomicInteropTestUtils} from "./AtomicInteropTestUtils.sol";

/// @notice End-to-end tests for the L1-free atomic interop flow. Two "chains" are simulated within
/// a single EVM via `vm.chainId`: each has its own commitment tree, importer and escrow. The flow
/// finalizes only when both legs are proven committed in time, and refunds when a leg is proven
/// absent across the deadline boundary — all without any L1 coordinator call.
contract AtomicFlowEscrowTest is Test {
    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;
    uint64 internal constant DEADLINE = 2000;

    GlobalInteropIMT internal registry;
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal supplier = makeAddr("supplier");

    // Per-chain stacks.
    L2InteropCommitmentTree internal treeA;
    L2InteropCommitmentTree internal treeB;
    L2GlobalInteropRootImporter internal importerA;
    L2GlobalInteropRootImporter internal importerB;
    AtomicFlowEscrow internal escrowA;
    AtomicFlowEscrow internal escrowB;
    TestnetERC20Token internal tokenA;
    TestnetERC20Token internal tokenB;

    address internal alice = makeAddr("alice"); // payer on A
    address internal bob = makeAddr("bob"); // payee on A
    address internal carol = makeAddr("carol"); // payer on B
    address internal dave = makeAddr("dave"); // payee on B

    function setUp() public {
        registry = new GlobalInteropIMT(owner);
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
        uint256[] memory chainIds = _chainIds();
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, chainIds, DEADLINE);

        // Commit both legs on their respective chains.
        _commit(escrowA, tokenA, CHAIN_A, alice, flowId, legA);
        _commit(escrowB, tokenB, CHAIN_B, carol, flowId, legB);

        // Expose both chains' IMT roots and import a global root timestamped before the deadline.
        uint256 l1Block = 100;
        _exposeAndImport(l1Block, 1500);

        // Build inclusion proofs for both legs (single-leaf trees -> empty IMT path).
        ImtInclusionProof[] memory proofs = new ImtInclusionProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            proofs[i] = _inclusionProof(legs[i].chainId, l1Block);
        }

        // Finalize on chain A then chain B.
        vm.chainId(CHAIN_A);
        escrowA.finalize(flowId, legs, chainIds, DEADLINE, proofs);
        vm.chainId(CHAIN_B);
        escrowB.finalize(flowId, legs, chainIds, DEADLINE, proofs);

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
        uint256[] memory chainIds = _chainIds();
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, chainIds, DEADLINE);

        _commit(escrowA, tokenA, CHAIN_A, alice, flowId, legA);
        _commit(escrowB, tokenB, CHAIN_B, carol, flowId, legB);

        // Imported with timestamp AFTER the deadline.
        uint256 l1Block = 100;
        _exposeAndImport(l1Block, 5000);

        ImtInclusionProof[] memory proofs = new ImtInclusionProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            proofs[i] = _inclusionProof(legs[i].chainId, l1Block);
        }

        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, 5000, DEADLINE));
        escrowA.finalize(flowId, legs, chainIds, DEADLINE, proofs);
    }

    function test_finalize_revertsOnFlowIdMismatch() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        FlowLeg memory legB = FlowLeg(CHAIN_B, address(tokenB), 50, carol, dave);
        (FlowLeg[] memory legs, bytes32[] memory specHashes) = _sorted(legA, legB);
        uint256[] memory chainIds = _chainIds();
        bytes32 realFlowId = AtomicInteropTestUtils.computeFlowId(specHashes, chainIds, DEADLINE);
        _commit(escrowA, tokenA, CHAIN_A, alice, realFlowId, legA);
        _commit(escrowB, tokenB, CHAIN_B, carol, realFlowId, legB);
        _exposeAndImport(100, 1500);

        ImtInclusionProof[] memory proofs = new ImtInclusionProof[](2);
        for (uint256 i = 0; i < 2; ++i) {
            proofs[i] = _inclusionProof(legs[i].chainId, 100);
        }

        bytes32 wrongFlowId = keccak256("wrong");
        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(EscrowFlowIdMismatch.selector, wrongFlowId, realFlowId));
        escrowA.finalize(wrongFlowId, legs, chainIds, DEADLINE, proofs);
    }

    // ── Timeout / refund path ───────────────────────────────────────────────────────────

    function test_refund_whenLegMissingAcrossDeadline() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        FlowLeg memory legB = FlowLeg(CHAIN_B, address(tokenB), 50, carol, dave);
        (FlowLeg[] memory legs, bytes32[] memory specHashes) = _sorted(legA, legB);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        // A commits. B never commits legB, but does commit an unrelated leg so its tree is non-empty.
        _commit(escrowA, tokenA, CHAIN_A, alice, flowId, legA);
        FlowLeg memory unrelated = FlowLeg(CHAIN_B, address(tokenB), 7, carol, dave);
        _commit(escrowB, tokenB, CHAIN_B, carol, keccak256("otherFlow"), unrelated);

        _exposeAndImportForRefund();

        // Non-inclusion proof for legB on chain B: chain B's only leaf is the unrelated one.
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = AtomicInteropTestUtils.commitLeaf(
            keccak256("otherFlow"),
            AtomicInteropTestUtils.specHashOf(unrelated)
        );

        uint256 aliceBefore = tokenA.balanceOf(alice);
        vm.chainId(CHAIN_A);
        escrowA.refund(flowId, legs, _chainIds(), DEADLINE, _missingIdx(legs), _nonInclusionProofB(leaves));

        assertEq(tokenA.balanceOf(alice), aliceBefore + 100, "alice refunded");
        assertTrue(escrowA.partState(flowId, AtomicInteropTestUtils.specHashOf(legA)) == PartState.Refunded);
    }

    function test_refund_revertsIfLegActuallyPresent() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        FlowLeg memory legB = FlowLeg(CHAIN_B, address(tokenB), 50, carol, dave);
        (FlowLeg[] memory legs, bytes32[] memory specHashes) = _sorted(legA, legB);
        bytes32 flowId = AtomicInteropTestUtils.computeFlowId(specHashes, _chainIds(), DEADLINE);

        // Both committed -> legB IS present in chain B's tree.
        _commit(escrowA, tokenA, CHAIN_A, alice, flowId, legA);
        _commit(escrowB, tokenB, CHAIN_B, carol, flowId, legB);

        _exposeAndImportForRefund();

        bytes32 legBLeaf = AtomicInteropTestUtils.commitLeaf(flowId, AtomicInteropTestUtils.specHashOf(legB));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = legBLeaf; // legB actually present -> non-inclusion must fail

        // Build the proof (which makes external reads) BEFORE expectRevert so it does not consume it.
        ImtNonInclusionProof memory proof = _nonInclusionProofB(leaves);
        uint256 missingIdx = _missingIdx(legs);
        uint256[] memory chainIds = _chainIds();

        vm.chainId(CHAIN_A);
        vm.expectRevert(abi.encodeWithSelector(ProofLeafPresent.selector, legBLeaf));
        escrowA.refund(flowId, legs, chainIds, DEADLINE, missingIdx, proof);
    }

    // ── commitPart edge cases ───────────────────────────────────────────────────────────

    function test_commitPart_revertsOnWrongChain() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        vm.chainId(CHAIN_B); // wrong chain for legA
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EscrowLegNotOnThisChain.selector, CHAIN_A));
        escrowA.commitPart(keccak256("f"), legA);
    }

    function test_commitPart_revertsOnPayerMismatch() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        vm.chainId(CHAIN_A);
        vm.prank(bob); // not the payer
        vm.expectRevert(abi.encodeWithSelector(EscrowPayerMismatch.selector, bob, alice));
        escrowA.commitPart(keccak256("f"), legA);
    }

    function test_commitPart_revertsOnZeroAmount() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 0, alice, bob);
        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.expectRevert(EscrowLegZeroAmount.selector);
        escrowA.commitPart(keccak256("f"), legA);
    }

    function test_commitPart_revertsOnDoubleCommit() public {
        FlowLeg memory legA = FlowLeg(CHAIN_A, address(tokenA), 100, alice, bob);
        bytes32 flowId = keccak256("f");
        _commit(escrowA, tokenA, CHAIN_A, alice, flowId, legA);
        bytes32 specHash = AtomicInteropTestUtils.specHashOf(legA);

        vm.chainId(CHAIN_A);
        vm.prank(alice);
        tokenA.approve(address(escrowA), 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EscrowPartNotUnset.selector, specHash, PartState.Committed));
        escrowA.commitPart(flowId, legA);
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────

    function _chainIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = CHAIN_A; // CHAIN_A < CHAIN_B
        ids[1] = CHAIN_B;
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
            legs[0] = _legA;
            legs[1] = _legB;
            specHashes[0] = hA;
            specHashes[1] = hB;
        } else {
            legs[0] = _legB;
            legs[1] = _legA;
            specHashes[0] = hB;
            specHashes[1] = hA;
        }
    }

    function _commit(
        AtomicFlowEscrow _escrow,
        TestnetERC20Token _token,
        uint256 _chainId,
        address _payer,
        bytes32 _flowId,
        FlowLeg memory _leg
    ) internal {
        vm.chainId(_chainId);
        vm.prank(_payer);
        _token.approve(address(_escrow), _leg.amount);
        vm.prank(_payer);
        _escrow.commitPart(_flowId, _leg);
    }

    /// @dev Submit both chains' current IMT roots to the registry and import the resulting global
    /// root into both importers at `_l1Block` / `_timestamp`.
    function _exposeAndImport(uint256 _l1Block, uint256 _timestamp) internal {
        // Hoist the external `root()` reads into locals so they do not consume the prank meant for
        // `submitChainRoot` (call arguments are evaluated before the call).
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

    function _missingIdx(FlowLeg[] memory _legs) internal pure returns (uint256) {
        return _legs[0].chainId == CHAIN_B ? 0 : 1;
    }

    /// @dev Submit both chains' roots, then import the same global root before AND after the
    /// deadline (chain B settles nothing new across the boundary).
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

    function _nonInclusionProofB(bytes32[] memory _leaves) internal view returns (ImtNonInclusionProof memory) {
        return
            ImtNonInclusionProof({
                chainId: CHAIN_B,
                chainImtRoot: treeB.root(),
                globalLeafIndex: registry.leafIndexOf(CHAIN_B),
                l1BlockNumberBeforeDeadline: 100,
                globalProofG1: registry.merklePathForChain(CHAIN_B),
                l1BlockNumberAfterDeadline: 200,
                globalProofG2: registry.merklePathForChain(CHAIN_B),
                leaves: _leaves
            });
    }

    /// @dev Builds an inclusion proof for a single-leaf chain IMT (empty IMT path) plus the global
    /// path from the registry.
    function _inclusionProof(uint256 _chainId, uint256 _l1Block) internal view returns (ImtInclusionProof memory) {
        bytes32 chainRoot = _chainId == CHAIN_A ? treeA.root() : treeB.root();
        return
            ImtInclusionProof({
                chainId: _chainId,
                chainImtRoot: chainRoot,
                imtLeafIndex: 0,
                imtProof: new bytes32[](0),
                globalLeafIndex: registry.leafIndexOf(_chainId),
                globalProof: registry.merklePathForChain(_chainId),
                l1BlockNumber: _l1Block
            });
    }
}
