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

/// @notice Unit tests for the {AtomicInteropProof} library (cross-chain authentication + clock logic
/// of the atomic interop flow; the protocol itself is described in the library header).
/// Atomicity is deployed only on L1-settled ecosystems, so every fixture uses a single L1 settlement
/// layer (`SETTLEMENT_LAYER_CHAIN_ID`).
///
/// The IMT membership half is driven against a REAL {L2InteropCommitmentTree} (the oracle) and the
/// timeout settlement-layer interop root tuples against a REAL {L2InteropRootStorage} seeded through the production
/// bootloader entry point; the cross-chain leaf verifier is mocked (isolating the separately-tested
/// leaf-inclusion layer) while the real `settlementProof` blob is still parsed by {MessageHashing},
/// so the settlement-layer / clock / last-batch / inclusion branches all run for real. See
/// {AtomicInteropProofBuilder}.
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
        // The leaf verifier is authenticated-true by default; individual reverts re-mock it to false.
        _mockVerifier(true);
        // The default settlement-layer interop root every timeout test resolves against: created strictly after the
        // deadline, seeded through the real storage's production entry point.
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

    // ============ verifyInclusion — happy / boundary ============

    function test_verifyInclusion_happy() public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1 // settled before the deadline
        );
        // Outcome under test: an in-time inclusion proof does NOT revert, and the claimed IMT root is
        // authenticated as exactly the batch-END chain-batch-root leaf (leaf 3).
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Boundary: `l1Timestamp == deadline` is in time (the check is strictly `>`).
    function test_verifyInclusion_allowsBatchSettledAtDeadline() public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE
        );
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
    /// a longer path could descend INTO the IMT and pass off an internal node as "the root".
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
        // Rebuild the metadata word with a deeper top-tree section (contents are irrelevant: the
        // depth check runs before any hashing).
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

    function test_RevertWhen_inclusion_deadlineExceeded() public {
        uint256 lateTimestamp = uint256(DEADLINE) + 1;
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            lateTimestamp
        );
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, lateTimestamp, DEADLINE));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Correct commit value + correct settlement/deadline, but the membership proof does not hash to
    /// the claimed root: the IMT check fails (distinct from a value/leaf mismatch, which the engine catches
    /// earlier). We keep the real leaf (so `leaf.value == commitValue`) and only corrupt `chainImtRoot`.
    function test_RevertWhen_inclusion_inclusionFailed() public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        proof.chainImtRoot = WRONG_ROOT;
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofInclusionFailed.selector, WRONG_ROOT, committedValue));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_inclusion_commitValueMismatch() public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        uint256 wrongCommitValue = absentValue;
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(IMTLeafValueMismatch.selector, wrongCommitValue, committedValue));
        proofLib.verifyInclusion(proof, wrongCommitValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ verifyTimeoutAbsence — happy / boundary ============

    /// @dev Late-batch branch: `t > deadline` selects the batch-BEGIN root (leaf 2); absence there
    /// means the value was never committed in time.
    function test_verifyTimeoutAbsence_lateBatch_happy() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Halted-chain branch: `t <= deadline` (pinned exactly AT the boundary) selects the
    /// batch-END root (leaf 3) and requires the batch to be the chain's LAST inside the settlement-layer interop root —
    /// trivially true for the empty batch-leaf path of a single-leaf chain tree.
    function test_verifyTimeoutAbsence_inTimeLastBatch_happy() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE
        );
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The last-batch check accepts a deeper batch-leaf path whose right siblings are the
    /// `DynamicIncrementalMerkle` empty-subtree cascade (a real last leaf in a grown chain tree).
    function test_verifyTimeoutAbsence_inTimeLastBatch_acceptsEmptySubtreeCascade() public {
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

    // ============ verifyTimeoutAbsence — reverts ============

    /// @dev Boundary: an settlement-layer interop root created exactly AT the deadline is not strictly after it — the
    /// stale/genesis-root guard (an in-time snapshot proves nothing about the deadline moment).
    function test_RevertWhen_timeout_interopRootAtDeadline() public {
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

    /// @dev In-time branch with a batch that is NOT the chain's last inside the settlement-layer interop root: the
    /// batch-leaf path carries a populated (non-empty-subtree) right sibling, so a later batch —
    /// which may contain the commit — exists and the proof is rejected.
    function test_RevertWhen_timeout_inTimeBatchNotLastInRoot() public {
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

    /// @dev The declared branch must match the authenticated inclusion time: the begin root proves
    /// nothing for an in-time batch (its begin state predates the deadline moment).
    function test_RevertWhen_timeout_beginBranchWithInTimeBatch() public {
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
    /// that fails the in-time branch is accepted when `t > deadline` (begin-root branch).
    function test_verifyTimeoutAbsence_lateBatchNeedsNoLastBatchProperty() public {
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

    function test_RevertWhen_timeout_nonInclusionFailed() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            uint256(DEADLINE) + 1
        );
        // The low-nullifier leaf brackets `absentValue`, but the membership path no longer hashes to the
        // claimed root, so absence is not certified.
        absence.chainImtRoot = WRONG_ROOT;
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofNonInclusionFailed.selector, WRONG_ROOT, absentValue));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ inclusion / timeout mutual exclusivity (library-level anti-double-mint) ============

    /// @dev A value that is present in the tree cannot also be given a valid non-inclusion proof: its
    /// predecessor leaf's `nextValue` equals the value, so the engine rejects the bracketing claim. This is
    /// the library-level guarantee that a leg cannot be simultaneously finalizable (included in time) and
    /// refundable (proven absent). Note: this library does not check that an absence proof targets the
    /// leg's own source chain; that binding (which blocks a cross-chain force-refund) is enforced by the
    /// caller, `AtomicFlowManager.authorizeRefund`, so it is out of scope for this library-level test.
    function test_includedValueCannotBeProvenAbsent() public {
        // Sanity: the committed value verifies as included in time.
        ImtProof memory inclusion = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            SL_BLOCK,
            DEADLINE - 1
        );
        _expectRootAuthentication(inclusion, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(inclusion, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);

        // Build an (illegitimate) absence proof using the committed value's true predecessor leaf,
        // against a late batch inside the post-deadline settlement-layer interop root.
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

    /// @dev Across the deadline boundary, an inclusion proof passes iff `l1Timestamp <= deadline`.
    function testFuzz_verifyInclusion_deadlineBoundary(uint64 _l1Timestamp, uint64 _deadline) public {
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

    /// @dev Timeout succeeds iff the settlement-layer interop root is strictly after the deadline (`T > deadline`).
    /// Notably `T <= deadline` must FAIL regardless of the batch's own timestamp — that is the guard
    /// that a stale/genesis root cannot force a refund. Both branches (late batch -> begin root,
    /// in-time last batch -> end root) are exercised by the fuzzed batch timestamp.
    function testFuzz_verifyTimeoutAbsence_interopRootWindow(
        uint64 _batchTimestamp,
        uint64 _interopRootTimestamp,
        uint64 _deadline
    ) public {
        vm.assume(_interopRootTimestamp != 0); // 0 == "never seeded"; covered by its own test
        uint256 slBlock = SL_BLOCK + 10; // fresh key per run; fuzz runs revert state after each run
        _seedSettlementLayerInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, slBlock, _interopRootTimestamp);

        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            slBlock,
            _batchTimestamp
        );
        // The builder declares the branch against the fixed test DEADLINE; re-declare it against the
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
