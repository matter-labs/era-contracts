// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {
    ProofImtRootInclusionFailed,
    ProofInvalidChainBatchRootDepth,
    ProofMissingSettlementLayerBatch,
    ProofDeadlineExceeded,
    ProofInteropRootNotAfterDeadline,
    ProofSettlementLayerInteropRootNotImported,
    ProofNotLastBatchInRoot,
    ProofTimeoutBranchMismatch,
    ProofInclusionFailed,
    ProofNonInclusionFailed,
    ProofSettlementLayerMismatch
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IMTLeafValueMismatch, IMTLowLeafNextTooSmall} from "contracts/common/L1ContractErrors.sol";

/// @notice Covers the {AtomicInteropProof} library — cross-chain authentication and clock logic of the
/// atomic finalize/timeout proofs. See {protocol-docs/atomicity/proofs.md}. Atomicity is deployed only on
/// L1-settled ecosystems, so every fixture uses a single L1 settlement layer.
/// @dev The happy paths run END-TO-END with nothing mocked: the commit value is aggregated into a REAL
/// {L1MessageRoot}, imported into the REAL {L2InteropRootStorage}, and authenticated through the REAL
/// {L2MessageVerification} (see {AtomicInteropProofBuilder}'s `_real*` helpers).
///
/// The negative and branch-shape cases isolate a SINGLE library branch (chain-batch-root depth, the
/// last-batch empty-subtree cascade at a chosen level/mask, a final-node proof, a forced verifier
/// failure) by crafting a synthetic `settlementProof` blob that real aggregation cannot produce — a
/// grown chain-batch tree with a specific mask, a wrong-level cascade sibling, etc. Those cases (and
/// only those) keep a documented `_mockVerifier` stub over the separately-tested leaf verifier; the
/// real `settlementProof` blob is still parsed by {MessageHashing}, so the settlement-layer / clock /
/// last-batch / inclusion branches all run for real. The deeper non-leftmost last-batch shape is also
/// exercised end-to-end by {AtomicInteropProofRealVerification}.
contract AtomicInteropProofTest is AtomicInteropProofBuilder {
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1; // L1
    uint256 internal constant BATCH_N = 100;
    uint256 internal constant SL_BLOCK = 555;

    bytes32 internal constant WRONG_ROOT = bytes32(uint256(0x1234));

    uint256 internal committedValue;
    uint256 internal committedIndex;
    uint256 internal absentValue;

    function setUp() public {
        _setUpAtomicFixtures();
        // No global verifier mock: happy paths authenticate through the real verifier. Branch-isolation
        // cases below re-establish a local `_mockVerifier(true/false)` over their synthetic blobs.
        // The default settlement-layer interop root the crafted-blob timeout cases resolve against:
        // created strictly after the deadline, seeded through the real storage's production entry point.
        _seedSettlementLayerInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, uint256(DEADLINE) + 1);

        committedValue = _commitValue(keccak256("flowA"), keccak256("bundleA"));
        committedIndex = _insertCommit(committedValue);

        // A value for a flow that was never committed on this chain (used by the timeout/absence tests).
        absentValue = _commitValue(keccak256("flowB"), keccak256("bundleB"));
    }

    // ============ commitValue ============

    function testFuzz_commitValue_matchesSpec(bytes32 _flowId, bytes32 _bundleHash) public view {
        assertEq(
            proofLib.commitValue(_flowId, _bundleHash),
            uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _bundleHash)))
        );
    }

    // ============ verifyInclusion — happy / boundary (real end-to-end) ============

    function test_verifyInclusion_happy() public {
        ImtProof memory proof = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, DEADLINE - 1);
        // Outcome under test: an in-time inclusion proof does NOT revert, and the claimed IMT root is
        // authenticated as exactly the batch-END chain-batch-root leaf (leaf 3).
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The timeout-branch flag is a NO-OP for inclusion: `verifyInclusion` always authenticates
    /// the batch-END root (leaf 3), whatever the prover declares. A flag-sensitive implementation
    /// could be steered to the begin root, where a same-batch commit is not yet present.
    function test_verifyInclusion_ignoresBeginBranchFlag() public {
        ImtProof memory proof = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, DEADLINE - 1);
        proof.provesAgainstBeginRoot = true;
        // Still the END leaf, and the proof still verifies.
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Boundary: `l1Timestamp == deadline` is in time (the check is strictly `>`).
    function test_verifyInclusion_allowsBatchSettledAtDeadline() public {
        ImtProof memory proof = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, DEADLINE);
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ verifyInclusion — reverts ============

    function test_RevertWhen_inclusion_imtRootInclusionFails() public {
        _mockVerifier(false);
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofImtRootInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_N, proof.chainImtRoot)
        );
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The leaf-to-chain-batch-root section must be exactly {ChainBatchRootTree.TREE_DEPTH} hops;
    /// a longer path could descend INTO the IMT and pass off an internal node as "the root". The depth
    /// check runs before the verifier, so no stub is needed.
    function test_RevertWhen_inclusion_invalidChainBatchRootDepth() public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        uint256 wrongDepth = ChainBatchRootTree.TREE_DEPTH + 1;
        // Contents are irrelevant: the depth check runs before any hashing.
        proof.settlementProof[0] = _composeMetadata({
            _logLeafProofLen: wrongDepth,
            _batchLeafProofLen: 0,
            _finalProofNode: false
        });
        vm.expectRevert(
            abi.encodeWithSelector(ProofInvalidChainBatchRootDepth.selector, ChainBatchRootTree.TREE_DEPTH, wrongDepth)
        );
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_inclusion_missingSettlementLayerBatch() public {
        // Branch isolation: a final-node blob cannot be produced by real aggregation, so the leaf
        // verifier is stubbed to reach the `finalProofNode` check.
        _mockVerifier(true);
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        // A final-node (single-level) proof carries no settlement-layer batch reference.
        proof.settlementProof = _finalSettlementProof();
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofMissingSettlementLayerBatch.selector, SOURCE_CHAIN_ID, BATCH_N));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_inclusion_settlementLayerMismatch() public {
        _mockVerifier(true);
        uint256 proofSl = SETTLEMENT_LAYER_CHAIN_ID + 1;
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            proofSl,
            SL_BLOCK,
            DEADLINE - 1
        );
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofSettlementLayerMismatch.selector, SETTLEMENT_LAYER_CHAIN_ID, proofSl)
        );
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Real end-to-end negative: a genuinely aggregated + imported batch whose inclusion time is
    /// past the deadline is rejected by the clock check (no stub — the verifier authenticates the real
    /// root, then the deadline comparison fires).
    function test_RevertWhen_inclusion_deadlineExceeded() public {
        uint256 lateTimestamp = uint256(DEADLINE) + 1;
        ImtProof memory proof = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, lateTimestamp);
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, lateTimestamp, DEADLINE));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Real end-to-end negative: correct commit value + correct settlement/deadline, but the
    /// membership path is corrupted so it no longer hashes to the (genuinely authenticated) root. The
    /// verifier still authenticates `chainImtRoot`; only the IMT membership check fails (distinct from a
    /// value/leaf mismatch, which the engine catches earlier).
    function test_RevertWhen_inclusion_inclusionFailed() public {
        ImtProof memory proof = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, DEADLINE - 1);
        proof.imtProof[0] = WRONG_ROOT; // corrupt the membership path, keep the real (authenticated) root
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofInclusionFailed.selector, proof.chainImtRoot, committedValue));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Real end-to-end negative: the leaf genuinely present at `committedIndex` holds
    /// `committedValue`, so verifying against a DIFFERENT expected value is caught by the IMT engine.
    function test_RevertWhen_inclusion_commitValueMismatch() public {
        ImtProof memory proof = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, DEADLINE - 1);
        uint256 wrongCommitValue = absentValue;
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(IMTLeafValueMismatch.selector, wrongCommitValue, committedValue));
        proofLib.verifyInclusion(proof, wrongCommitValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ verifyTimeoutAbsence — happy / boundary (real end-to-end) ============

    /// @dev Late-batch branch: `t > deadline` selects the batch-BEGIN root (leaf 2); absence there
    /// means the value was never committed in time.
    function test_verifyTimeoutAbsence_lateBatch_happy() public {
        ImtProof memory absence = _realTimeoutBeginProof(SOURCE_CHAIN_ID, absentValue, uint256(DEADLINE) + 1);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Halted-chain branch: `t <= deadline` (pinned exactly AT the boundary) selects the
    /// batch-END root (leaf 3) and requires the batch to be the chain's LAST inside the settlement-layer
    /// interop root — the source chain's single in-time batch is its last, and a later (peer-chain)
    /// aggregation pushes the imported root's creation time past the deadline.
    function test_verifyTimeoutAbsence_inTimeLastBatch_happy() public {
        ImtProof memory absence = _realTimeoutEndProof(SOURCE_CHAIN_ID, absentValue, DEADLINE);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The last-batch check accepts a deeper batch-leaf path whose right siblings are the
    /// `DynamicIncrementalMerkle` empty-subtree cascade (a real last leaf in a grown chain tree). A
    /// grown chain-batch tree with this shape cannot be produced by the single-batch aggregation
    /// helpers, so the leaf verifier is stubbed over the synthetic path.
    function test_verifyTimeoutAbsence_inTimeLastBatch_acceptsEmptySubtreeCascade() public {
        _mockVerifier(true);
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        absence.settlementProof = _settlementProof(
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1,
            _emptySubtreeCascade(2)
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev A last batch that is a RIGHT child (non-zero batch-leaf mask) is accepted: the last-batch
    /// check must skip right-child levels — their LEFT siblings are earlier, populated batches — and
    /// only require the empty-subtree cascade on left-child levels. Modeled: a 3-batch chain tree
    /// whose last leaf (index 2) sits at mask `0b10` — level 0 left child (right sibling = zeros[0]),
    /// level 1 right child (left sibling = the populated subtree of batches 0..1). Synthetic shape ->
    /// stubbed verifier; the real right-child last-leaf path is covered by
    /// {AtomicInteropProofRealVerification}.
    function test_verifyTimeoutAbsence_inTimeLastBatch_acceptsRightChildLastLeaf() public {
        _mockVerifier(true);
        bytes32[] memory siblings = new bytes32[](2);
        siblings[0] = _emptySubtreeCascade(1)[0];
        siblings[1] = keccak256("populated subtree of batches 0..1");

        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        absence.settlementProof = _settlementProofWithMask(
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1,
            2, // 0b10: left child at level 0, right child at level 1
            siblings
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // NOTE: the deeper-level non-last-batch rejection (mask 0b01, populated level-1 sibling) is pinned
    // through the REAL verifier in {AtomicInteropProofRealVerification}, not repeated here.

    /// @dev The empty-subtree cascade is LEVEL-SPECIFIC: `zeros[0]` presented at level 1 (where
    /// `zeros[1] = keccak(zeros[0] || zeros[0])` is required) does not certify an empty right
    /// subtree and is rejected. Guards the per-level cascade recomputation.
    function test_RevertWhen_timeout_wrongCascadeLevelSibling() public {
        _mockVerifier(true);
        bytes32 levelZeroHash = _emptySubtreeCascade(1)[0];
        bytes32[] memory siblings = new bytes32[](2);
        siblings[0] = levelZeroHash;
        siblings[1] = levelZeroHash; // wrong: level 1 requires keccak(zeros[0] || zeros[0])

        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        absence.settlementProof = _settlementProof(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, DEADLINE - 1, siblings);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofNotLastBatchInRoot.selector, 1, levelZeroHash));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ verifyTimeoutAbsence — reverts ============

    /// @dev Boundary: a settlement-layer interop root created exactly AT the deadline is not strictly
    /// after it — the stale/genesis-root guard (an in-time snapshot proves nothing about the deadline).
    function test_RevertWhen_timeout_interopRootAtDeadline() public {
        _mockVerifier(true);
        uint256 staleBlock = SL_BLOCK + 1;
        _seedSettlementLayerInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, staleBlock, DEADLINE);
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            staleBlock,
            DEADLINE - 1
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofInteropRootNotAfterDeadline.selector, uint256(DEADLINE), DEADLINE));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev A missing settlement interop root has an unset timestamp that reads as 0 and is rejected.
    function test_RevertWhen_timeout_missingSettlementInteropRoot() public {
        _mockVerifier(true);
        uint256 unseededBlock = SL_BLOCK + 2;
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            unseededBlock,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProofSettlementLayerInteropRootNotImported.selector,
                SETTLEMENT_LAYER_CHAIN_ID,
                unseededBlock
            )
        );
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev In-time batch that is NOT the chain's last inside the settlement-layer interop root: a
    /// populated right sibling means a later batch — which may contain the commit — exists, so rejected.
    function test_RevertWhen_timeout_inTimeBatchNotLastInRoot() public {
        _mockVerifier(true);
        bytes32 populatedSibling = keccak256("populated-right-subtree");
        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = populatedSibling;

        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        absence.settlementProof = _settlementProof(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, DEADLINE - 1, siblings);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofNotLastBatchInRoot.selector, 0, populatedSibling));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Boundary of the branch validation: a batch settled exactly AT the deadline is in time
    /// (`t <= deadline`, matching {verifyInclusion}'s clock), so the begin branch — which requires a
    /// strictly late batch — must reject it. Where the previous test pins `t < deadline`, this one
    /// pins the `t == deadline` edge, where begin-branch absence would contradict a same-batch
    /// finalization.
    function test_RevertWhen_timeout_beginBranchWithBatchAtDeadline() public {
        _mockVerifier(true);
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE
        );
        absence.provesAgainstBeginRoot = true;
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofTimeoutBranchMismatch.selector, true, uint256(DEADLINE), DEADLINE));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The declared branch must match the authenticated inclusion time: the begin root proves
    /// nothing for an in-time batch (its begin state predates the deadline moment).
    function test_RevertWhen_timeout_beginBranchWithInTimeBatch() public {
        _mockVerifier(true);
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        absence.provesAgainstBeginRoot = true;
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofTimeoutBranchMismatch.selector, true, uint256(DEADLINE) - 1, DEADLINE)
        );
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev ...and the end root is paired exclusively with the in-time last-batch branch: a late
    /// batch must use its begin root (which needs no last-batch property).
    function test_RevertWhen_timeout_endBranchWithLateBatch() public {
        _mockVerifier(true);
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );
        absence.provesAgainstBeginRoot = false;
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofTimeoutBranchMismatch.selector, false, uint256(DEADLINE) + 1, DEADLINE)
        );
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev A LATE batch does not need the last-batch property: the same populated batch-leaf path
    /// that fails the in-time branch is accepted when `t > deadline` (begin-root branch). Synthetic
    /// batch-leaf path -> stubbed verifier.
    function test_verifyTimeoutAbsence_lateBatchNeedsNoLastBatchProperty() public {
        _mockVerifier(true);
        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = keccak256("populated-right-subtree");

        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );
        absence.settlementProof = _settlementProof(
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1,
            siblings
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_timeout_missingSettlementLayerBatch() public {
        // Branch isolation: a final-node blob cannot be produced by real aggregation.
        _mockVerifier(true);
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );
        absence.settlementProof = _finalSettlementProof();
        vm.expectRevert(abi.encodeWithSelector(ProofMissingSettlementLayerBatch.selector, SOURCE_CHAIN_ID, BATCH_N));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_timeout_settlementLayerMismatch() public {
        _mockVerifier(true);
        uint256 proofSl = SETTLEMENT_LAYER_CHAIN_ID + 1;
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            proofSl,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofSettlementLayerMismatch.selector, SETTLEMENT_LAYER_CHAIN_ID, proofSl)
        );
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_timeout_imtRootInclusionFails() public {
        _mockVerifier(false);
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofImtRootInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_N, absence.chainImtRoot)
        );
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Real end-to-end negative: a genuine begin-branch absence proof whose membership path is
    /// then corrupted so it no longer hashes to the (authenticated) root — non-inclusion is not
    /// certified.
    function test_RevertWhen_timeout_nonInclusionFailed() public {
        ImtProof memory absence = _realTimeoutBeginProof(SOURCE_CHAIN_ID, absentValue, uint256(DEADLINE) + 1);
        absence.imtProof[0] = WRONG_ROOT; // corrupt the low-nullifier path, keep the real root
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofNonInclusionFailed.selector, absence.chainImtRoot, absentValue));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ inclusion / timeout mutual exclusivity (library-level anti-double-mint) ============

    /// @dev Library-level anti-double-mint: a present value's predecessor leaf has `nextValue == value`,
    /// so the bracketing (absence) claim is rejected — a leg cannot be both finalizable and refundable.
    /// Binding an absence proof to the leg's own source chain is the caller's job
    /// (`AtomicFlowManager.authorizeRefund`) and out of scope here. See {protocol-docs/atomicity/proofs.md#soundness}.
    /// The inclusion half runs end-to-end (real aggregation); the illegitimate absence half crafts a
    /// begin-root proof from the real tree's predecessor leaf, so its verifier is stubbed.
    function test_includedValueCannotBeProvenAbsent() public {
        // Sanity: the committed value verifies as included in time (real, unmocked).
        ImtProof memory inclusion = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, DEADLINE - 1);
        _expectRootAuthentication(inclusion, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(inclusion, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);

        // Forge an absence proof from the committed value's true predecessor leaf, against a late batch
        // inside the post-deadline settlement-layer interop root (crafted blob, so the verifier is stubbed).
        _mockVerifier(true);
        uint256 predIndex = _predecessorIndexOf(committedValue);
        ImtProof memory absence = ImtProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_N,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: true,
            settlementProof: _settlementProof(
                SETTLEMENT_LAYER_CHAIN_ID,
                SL_BLOCK,
                uint256(DEADLINE) + 1,
                new bytes32[](0)
            ),
            leaf: tree.leafAt(predIndex),
            imtLeafIndex: predIndex,
            imtProof: tree.merklePath(predIndex)
        });

        // The predecessor's `nextValue == committedValue`, so non-inclusion is rejected by the IMT engine.
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafNextTooSmall.selector, committedValue, committedValue));
        proofLib.verifyTimeoutAbsence(absence, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ fuzz ============

    /// @dev Across the deadline boundary, an inclusion proof passes iff `l1Timestamp <= deadline`. Each
    /// run builds a synthetic well-formed blob carrying the fuzzed timestamp over the stubbed verifier
    /// (re-aggregating a real proof per iteration would be prohibitive); the clock's binding into a REAL
    /// authenticated proof is pinned by the non-fuzz deadline tests above.
    function testFuzz_verifyInclusion_deadlineBoundary(uint64 _l1Timestamp, uint64 _deadline) public {
        _mockVerifier(true);
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            _l1Timestamp
        );
        if (uint256(_l1Timestamp) > uint256(_deadline)) {
            vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, uint256(_l1Timestamp), _deadline));
        }
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(proof, committedValue, _deadline, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Timeout passes iff the settlement-layer interop root is strictly after the deadline;
    /// `T <= deadline` must FAIL regardless of the batch's own timestamp (stale/genesis-root guard).
    /// Both branches (late batch -> begin root, in-time last batch -> end root) are fuzzed.
    function testFuzz_verifyTimeoutAbsence_interopRootWindow(
        uint64 _batchTimestamp,
        uint64 _interopRootTimestamp,
        uint64 _deadline
    ) public {
        _mockVerifier(true);
        vm.assume(_interopRootTimestamp != 0); // 0 == "never seeded"; covered by its own test
        uint256 slBlock = SL_BLOCK + 10; // avoid the setUp-seeded key
        _seedSettlementLayerInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, slBlock, _interopRootTimestamp);

        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            slBlock,
            _batchTimestamp
        );
        // The builder declares the branch against the fixed test DEADLINE; redeclare it against the
        // fuzzed deadline the way an honest prover would.
        absence.provesAgainstBeginRoot = uint256(_batchTimestamp) > uint256(_deadline);
        uint256 imtRootLeafIndex = absence.provesAgainstBeginRoot
            ? ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX
            : ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX;
        if (uint256(_interopRootTimestamp) <= uint256(_deadline)) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ProofInteropRootNotAfterDeadline.selector,
                    uint256(_interopRootTimestamp),
                    _deadline
                )
            );
        }
        _expectRootAuthentication(absence, imtRootLeafIndex);
        proofLib.verifyTimeoutAbsence(absence, absentValue, _deadline, SETTLEMENT_LAYER_CHAIN_ID);
    }
}
