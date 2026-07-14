// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ProofRootMessageInclusionFailed,
    ProofMissingSettlementLayerAnchor,
    ProofDeadlineExceeded,
    ProofDeadlineNotExceeded,
    ProofInclusionFailed,
    ProofNonInclusionFailed,
    ProofSettlementLayerMismatch,
    ProofSourceChainMismatch,
    ProofAdjacencyNotConsecutive
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IMTLeafValueMismatch, IMTLowLeafNextTooSmall} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for the {AtomicInteropProof} library (cross-chain authentication + deadline logic
/// of the L1-free atomic interop flow). Atomicity is deployed only on L1-settled ecosystems, so every
/// fixture uses a single L1 settlement layer (`SETTLEMENT_LAYER_CHAIN_ID`).
///
/// Both halves run for real: the IMT membership half is driven against a REAL {L2InteropCommitmentTree}
/// (the oracle), and the cross-chain authentication half against the REAL {L2MessageVerification} + a real
/// interop-root storage. Each proof is a genuine inclusion proof whose imported root the builder seeds
/// (see {AtomicInteropProofBuilder} / {InteropInclusionProofLib}); the "root not included" branch is
/// reached by withholding that seed, never by mocking the verifier.
contract AtomicInteropProofTest is AtomicInteropProofBuilder {
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1; // L1
    uint256 internal constant BATCH_N = 100;
    uint64 internal constant DEADLINE = 1_000;

    uint256 internal committedValue;
    uint256 internal committedIndex;
    uint256 internal absentValue;

    function setUp() public {
        _setUpAtomicFixtures();

        committedValue = _commitValue(keccak256("flowA"), keccak256("bundleA"));
        committedIndex = _insertCommit(committedValue);

        // A value for a flow that was never committed on this chain (used by the timeout/absence tests).
        absentValue = _commitValue(keccak256("flowB"), keccak256("bundleB"));
    }

    /// @dev Perturbs a membership path so it no longer hashes to the tree root, without touching the
    /// leaf value — the IMT engine then reports non-membership rather than a value mismatch.
    function _corruptMembershipPath(bytes32[] memory _path) internal pure {
        _path[0] = bytes32(uint256(_path[0]) ^ 1);
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
            DEADLINE - 1 // settled before the deadline
        );
        // Outcome under test: an in-time, correctly-authenticated inclusion proof does NOT revert.
        _expectRootAuthentication(proof);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The root-authentication adapter must forward both message coordinates. A wider log tree with a
    /// non-zero `txNumberInBatch` / `messageIndex` binds them into the proven leaf, so if either coordinate
    /// were dropped the (real) verifier could not reconstruct the imported root.
    function test_verifyInclusion_forwardsNonZeroMessageCoordinatesToVerifier() public {
        bytes32[] memory logSiblings = new bytes32[](1);
        logSiblings[0] = keccak256("sibling-log");

        ImtProof memory proof = _inclusionProofWithCoordinates(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1,
            7, // txNumberInBatch
            1, // messageIndex (message sits at index 1 under logSiblings[0])
            logSiblings
        );

        _expectRootAuthentication(proof);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Boundary: `l1Timestamp == deadline` is in time (the check is strictly `>`).
    function test_verifyInclusion_allowsBatchSettledAtDeadline() public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE
        );
        _expectRootAuthentication(proof);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ verifyInclusion — reverts ============

    /// @dev The imported root is never seeded, so the real verifier cannot authenticate the root message.
    function test_RevertWhen_inclusion_rootMessageInclusionFails() public {
        ImtProof memory proof = _unresolvedInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1
        );
        _expectRootAuthentication(proof);
        vm.expectRevert(abi.encodeWithSelector(ProofRootMessageInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_N));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_inclusion_missingSettlementLayerAnchor() public {
        // A final-node (single-level) proof authenticates but carries no settlement-layer anchor.
        ImtProof memory proof = _missingAnchorProof(SOURCE_CHAIN_ID, BATCH_N, committedIndex);
        _expectRootAuthentication(proof);
        vm.expectRevert(abi.encodeWithSelector(ProofMissingSettlementLayerAnchor.selector, SOURCE_CHAIN_ID, BATCH_N));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_inclusion_settlementLayerMismatch() public {
        uint256 proofSl = SETTLEMENT_LAYER_CHAIN_ID + 1;
        ImtProof memory proof = _inclusionProof(SOURCE_CHAIN_ID, BATCH_N, committedIndex, proofSl, DEADLINE - 1);
        _expectRootAuthentication(proof);
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
            lateTimestamp
        );
        _expectRootAuthentication(proof);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, lateTimestamp, DEADLINE));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Correct commit value + correct settlement/deadline + authenticated root, but the membership
    /// proof does not hash to the tree root: the IMT check fails (distinct from a value/leaf mismatch,
    /// which the engine catches earlier). We keep the authenticated root real and only corrupt the
    /// membership path, so the failure is isolated to the IMT half.
    function test_RevertWhen_inclusion_inclusionFailed() public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1
        );
        _corruptMembershipPath(proof.imtProof);
        _expectRootAuthentication(proof);
        vm.expectRevert(abi.encodeWithSelector(ProofInclusionFailed.selector, proof.chainImtRoot, committedValue));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_inclusion_commitValueMismatch() public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1
        );
        uint256 wrongCommitValue = absentValue;
        _expectRootAuthentication(proof);
        vm.expectRevert(abi.encodeWithSelector(IMTLeafValueMismatch.selector, wrongCommitValue, committedValue));
        proofLib.verifyInclusion(proof, wrongCommitValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ verifyTimeoutAdjacency — happy / boundary ============

    function test_verifyTimeoutAdjacency_happy() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1 // batch N settled before the deadline
        );
        ImtProof memory successor = _rootAuthProof(
            SOURCE_CHAIN_ID,
            BATCH_N + 1,
            SETTLEMENT_LAYER_CHAIN_ID,
            uint256(DEADLINE) + 1 // batch N+1 settled after the deadline, pinning N as last in-time
        );
        _expectRootAuthentication(absence);
        _expectRootAuthentication(successor);
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Boundary: absence batch `t_N == deadline` is still in time (`t_N <= deadline`).
    function test_verifyTimeoutAdjacency_allowsAbsenceBatchSettledAtDeadline() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE
        );
        ImtProof memory successor = _rootAuthProof(
            SOURCE_CHAIN_ID,
            BATCH_N + 1,
            SETTLEMENT_LAYER_CHAIN_ID,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence);
        _expectRootAuthentication(successor);
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Boundary: successor `t_{N+1} == deadline` is NOT strictly after the deadline, so N is not
    /// pinned as the last in-time batch — this is the stale/genesis-root guard.
    function test_RevertWhen_timeout_successorTimestampEqualsDeadline() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1
        );
        ImtProof memory successor = _rootAuthProof(SOURCE_CHAIN_ID, BATCH_N + 1, SETTLEMENT_LAYER_CHAIN_ID, DEADLINE);
        _expectRootAuthentication(absence);
        _expectRootAuthentication(successor);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineNotExceeded.selector, uint256(DEADLINE), DEADLINE));
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ verifyTimeoutAdjacency — reverts ============

    function test_RevertWhen_timeout_absenceDeadlineExceeded() public {
        uint256 lateTimestamp = uint256(DEADLINE) + 1;
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            lateTimestamp
        );
        ImtProof memory successor = _rootAuthProof(
            SOURCE_CHAIN_ID,
            BATCH_N + 1,
            SETTLEMENT_LAYER_CHAIN_ID,
            lateTimestamp + 1
        );
        _expectRootAuthentication(absence);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, lateTimestamp, DEADLINE));
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The low-nullifier leaf brackets `absentValue`, but its membership path no longer hashes to the
    /// tree root, so absence is not certified. The authenticated root stays real.
    function test_RevertWhen_timeout_nonInclusionFailed() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1
        );
        _corruptMembershipPath(absence.imtProof);
        ImtProof memory successor = _rootAuthProof(
            SOURCE_CHAIN_ID,
            BATCH_N + 1,
            SETTLEMENT_LAYER_CHAIN_ID,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence);
        vm.expectRevert(abi.encodeWithSelector(ProofNonInclusionFailed.selector, absence.chainImtRoot, absentValue));
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_timeout_successorSourceChainMismatch() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1
        );
        uint256 wrongSuccessorChain = SOURCE_CHAIN_ID + 1;
        ImtProof memory successor = _rootAuthProof(
            wrongSuccessorChain,
            BATCH_N + 1,
            SETTLEMENT_LAYER_CHAIN_ID,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence);
        _expectRootAuthentication(successor);
        vm.expectRevert(
            abi.encodeWithSelector(ProofSourceChainMismatch.selector, SOURCE_CHAIN_ID, wrongSuccessorChain)
        );
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_timeout_absenceSettlementLayerMismatch() public {
        uint256 proofSl = SETTLEMENT_LAYER_CHAIN_ID + 1;
        ImtProof memory absence = _nonInclusionProof(SOURCE_CHAIN_ID, BATCH_N, absentValue, proofSl, DEADLINE - 1);
        ImtProof memory successor = _rootAuthProof(
            SOURCE_CHAIN_ID,
            BATCH_N + 1,
            SETTLEMENT_LAYER_CHAIN_ID,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence);
        vm.expectRevert(
            abi.encodeWithSelector(ProofSettlementLayerMismatch.selector, SETTLEMENT_LAYER_CHAIN_ID, proofSl)
        );
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_timeout_successorSettlementLayerMismatch() public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1
        );
        uint256 successorSl = SETTLEMENT_LAYER_CHAIN_ID + 1;
        ImtProof memory successor = _rootAuthProof(SOURCE_CHAIN_ID, BATCH_N + 1, successorSl, uint256(DEADLINE) + 1);
        _expectRootAuthentication(absence);
        _expectRootAuthentication(successor);
        vm.expectRevert(
            abi.encodeWithSelector(ProofSettlementLayerMismatch.selector, SETTLEMENT_LAYER_CHAIN_ID, successorSl)
        );
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
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
            DEADLINE - 1
        );
        _expectRootAuthentication(inclusion);
        proofLib.verifyInclusion(inclusion, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);

        // Build an (illegitimate) absence proof using the committed value's true predecessor leaf,
        // authenticated by a real, seeded root proof.
        uint256 predIndex = _predecessorIndexOf(committedValue);
        ImtProof memory absence = ImtProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_N,
            chainImtRoot: tree.root(),
            messageTxNumberInBatch: 0,
            messageIndex: 0,
            messageProof: _seededRootProof(SOURCE_CHAIN_ID, BATCH_N, SETTLEMENT_LAYER_CHAIN_ID, DEADLINE - 1),
            leaf: tree.leafAt(predIndex),
            imtLeafIndex: predIndex,
            imtProof: tree.merklePath(predIndex)
        });
        ImtProof memory successor = _rootAuthProof(
            SOURCE_CHAIN_ID,
            BATCH_N + 1,
            SETTLEMENT_LAYER_CHAIN_ID,
            uint256(DEADLINE) + 1
        );

        // The predecessor's `nextValue == committedValue`, so non-inclusion is rejected by the IMT engine.
        _expectRootAuthentication(absence);
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafNextTooSmall.selector, committedValue, committedValue));
        proofLib.verifyTimeoutAdjacency(absence, successor, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ fuzz ============

    /// @dev Across the deadline boundary, an inclusion proof passes iff `l1Timestamp <= deadline`.
    function testFuzz_verifyInclusion_deadlineBoundary(uint64 _l1Timestamp, uint64 _deadline) public {
        ImtProof memory proof = _inclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            committedIndex,
            SETTLEMENT_LAYER_CHAIN_ID,
            _l1Timestamp
        );
        if (uint256(_l1Timestamp) > uint256(_deadline)) {
            vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, uint256(_l1Timestamp), _deadline));
        }
        _expectRootAuthentication(proof);
        proofLib.verifyInclusion(proof, committedValue, _deadline, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Timeout succeeds iff the absence batch is in time AND its successor is strictly late
    /// (`t_N <= deadline && t_{N+1} > deadline`). Notably, `t_N <= deadline && t_{N+1} <= deadline` must
    /// FAIL — that is the guard that a stale/genesis root cannot force a refund.
    function testFuzz_verifyTimeoutAdjacency_deadlineWindow(uint64 _tN, uint64 _tS, uint64 _deadline) public {
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            _tN
        );
        ImtProof memory successor = _rootAuthProof(SOURCE_CHAIN_ID, BATCH_N + 1, SETTLEMENT_LAYER_CHAIN_ID, _tS);
        bool inTimeWindow = (uint256(_tN) <= uint256(_deadline)) && (uint256(_tS) > uint256(_deadline));
        if (!inTimeWindow) {
            if (uint256(_tN) > uint256(_deadline)) {
                vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, uint256(_tN), _deadline));
            } else {
                vm.expectRevert(abi.encodeWithSelector(ProofDeadlineNotExceeded.selector, uint256(_tS), _deadline));
            }
        }
        _expectRootAuthentication(absence);
        if (uint256(_tN) <= uint256(_deadline)) {
            _expectRootAuthentication(successor);
        }
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, _deadline, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The adjacency witness must be exactly `absence.batchNumber + 1`.
    function testFuzz_verifyTimeoutAdjacency_adjacency(uint256 _successorBatch) public {
        vm.assume(_successorBatch != BATCH_N + 1);
        ImtProof memory absence = _nonInclusionProof(
            SOURCE_CHAIN_ID,
            BATCH_N,
            absentValue,
            SETTLEMENT_LAYER_CHAIN_ID,
            DEADLINE - 1
        );
        ImtProof memory successor = _rootAuthProof(
            SOURCE_CHAIN_ID,
            _successorBatch,
            SETTLEMENT_LAYER_CHAIN_ID,
            uint256(DEADLINE) + 1
        );
        _expectRootAuthentication(absence);
        _expectRootAuthentication(successor);
        vm.expectRevert(abi.encodeWithSelector(ProofAdjacencyNotConsecutive.selector, BATCH_N, _successorBatch));
        proofLib.verifyTimeoutAdjacency(absence, successor, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }
}
