// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";
import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";

import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {L2_MESSAGE_VERIFICATION} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
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
/// @dev Every proof authenticates through the REAL {L2MessageVerification} against a root imported into the
/// REAL {L2InteropRootStorage}. The happy paths aggregate the commit value into a REAL {L1MessageRoot} (the
/// builder's `_real*` helpers). The branch-isolation cases need shapes live aggregation cannot produce (a
/// grown batch tree with a chosen mask, a final-node proof, another settlement layer, an arbitrary batch
/// time), so they forward-compute the proof with the builder's {_settlementProof} and import its root; the
/// authentication-failure cases withhold that import. The only stubbed verifier is in
/// `test_RevertWhen_timeout_missingSettlementInteropRoot`, whose branch the real one cannot reach by
/// construction.
contract AtomicInteropProofTest is AtomicInteropProofBuilder {
    /// @dev Per-suite proof fixture values. Not hoisted onto the builder: other derived suites pick
    /// their own (the execute abstract takes a fresh SL block per import).
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant BATCH_N = 100;
    uint256 internal constant SL_BLOCK = 555;

    bytes32 internal constant WRONG_ROOT = bytes32(uint256(0x1234));

    uint256 internal committedValue;
    uint256 internal committedIndex;
    uint256 internal absentValue;

    function setUp() public {
        _setUpAtomicFixtures();

        committedValue = AtomicFlowFixtures.commitValue(keccak256("flowA"), keccak256("bundleA"));
        committedIndex = _insertCommit(committedValue);

        // A value for a flow that was never committed on this chain (used by the timeout/absence tests).
        absentValue = AtomicFlowFixtures.commitValue(keccak256("flowB"), keccak256("bundleB"));
    }

    /// @dev Imports `_root` at the suite's settlement-layer key, created strictly after the deadline.
    function _importRoot(bytes32 _root) internal {
        _importInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, uint256(DEADLINE) + 1, _root);
    }

    // ============ commitValue ============

    /// @notice Pins the domain tag's literal value. {testFuzz_commitValue_matchesSpec} derives its
    /// expectation from the constant itself, so only this catches a change to the tag preimage.
    function test_commitValueDomainTag_isPinned() public pure {
        // solhint-disable-next-line quotes
        assertEq(ATOMIC_COMMIT_LEAF_TAG, bytes4(0x3445134c), 'keccak("AtomicInterop.commit.v1")[0:4]');
    }

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

    /// @dev The settlement root the proof reconstructs was never imported, so the real verifier rejects it.
    function test_RevertWhen_inclusion_imtRootInclusionFails() public {
        (ImtProof memory proof, ) = _inclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _leafIndex: committedIndex,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1
        });
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofImtRootInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_N, proof.chainImtRoot)
        );
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The leaf-to-chain-batch-root section must be exactly {ChainBatchRootTree.TREE_DEPTH} hops;
    /// a longer path could descend INTO the IMT and pass off an internal node as "the root". The depth
    /// check runs before the verifier, so no root is imported.
    function test_RevertWhen_inclusion_invalidChainBatchRootDepth() public {
        (ImtProof memory proof, ) = _inclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _leafIndex: committedIndex,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1
        });
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

    /// @dev The symmetric direction: without it the depth equality can be weakened to `>`, still
    /// rejecting the over-long path above while accepting one that stops short of the root.
    function test_RevertWhen_inclusion_chainBatchRootDepthTooShort() public {
        (ImtProof memory proof, ) = _inclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _leafIndex: committedIndex,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1
        });
        uint256 shortDepth = ChainBatchRootTree.TREE_DEPTH - 1;
        proof.settlementProof[0] = _composeMetadata({
            _logLeafProofLen: shortDepth,
            _batchLeafProofLen: 0,
            _finalProofNode: false
        });
        vm.expectRevert(
            abi.encodeWithSelector(ProofInvalidChainBatchRootDepth.selector, ChainBatchRootTree.TREE_DEPTH, shortDepth)
        );
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev A final-node (single-level) proof carries no settlement-layer batch reference. The real
    /// verifier accepts it against the source chain's own imported batch root, so the library's check
    /// is what rejects it.
    function test_RevertWhen_inclusion_missingSettlementLayerBatch() public {
        (ImtProof memory proof, ) = _inclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _leafIndex: committedIndex,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1
        });
        bytes32 chainBatchRoot;
        (proof.settlementProof, chainBatchRoot) = _finalSettlementProof({
            _imtRoot: proof.chainImtRoot,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _otherImtRoot: OTHER_IMT_ROOT
        });
        _importInteropRoot(SOURCE_CHAIN_ID, BATCH_N, uint256(DEADLINE) + 1, chainBatchRoot);
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofMissingSettlementLayerBatch.selector, SOURCE_CHAIN_ID, BATCH_N));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_inclusion_settlementLayerMismatch() public {
        uint256 proofSl = SETTLEMENT_LAYER_CHAIN_ID + 1;
        (ImtProof memory proof, bytes32 aggregatedRoot) = _inclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _leafIndex: committedIndex,
            _slChainId: proofSl,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1
        });
        // Authentic on its own settlement layer, which is not the flow's.
        _importInteropRoot(proofSl, SL_BLOCK, uint256(DEADLINE) + 1, aggregatedRoot);
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
    /// `DynamicIncrementalMerkle` empty-subtree cascade (a real last leaf in a grown chain tree), which
    /// the single-batch aggregation helpers cannot produce.
    function test_verifyTimeoutAbsence_inTimeLastBatch_acceptsEmptySubtreeCascade() public {
        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: _emptySubtreeCascade(2)
        });
        _importRoot(aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev A last batch that is a RIGHT child (non-zero batch-leaf mask) is accepted: the last-batch
    /// check must skip right-child levels — their LEFT siblings are earlier, populated batches — and
    /// only require the empty-subtree cascade on left-child levels. Modeled: a 3-batch chain tree
    /// whose last leaf (index 2) sits at mask `0b10` — level 0 left child (right sibling = zeros[0]),
    /// level 1 right child (left sibling = the populated subtree of batches 0..1). The mirrored mask
    /// `0b01` is pinned by {AtomicInteropProofRealVerification}.
    function test_verifyTimeoutAbsence_inTimeLastBatch_acceptsRightChildLastLeaf() public {
        bytes32[] memory siblings = new bytes32[](2);
        siblings[0] = _emptySubtreeCascade(1)[0];
        siblings[1] = keccak256("populated subtree of batches 0..1");

        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1,
            _batchLeafProofMask: 2, // 0b10: left child at level 0, right child at level 1
            _batchLeafSiblings: siblings
        });
        _importRoot(aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // NOTE: the deeper-level non-last-batch rejection (mask 0b01, populated level-1 sibling) is pinned
    // in {AtomicInteropProofRealVerification}, not repeated here.

    /// @dev The empty-subtree cascade is LEVEL-SPECIFIC: `zeros[0]` presented at level 1 (where
    /// `zeros[1] = keccak(zeros[0] || zeros[0])` is required) does not certify an empty right
    /// subtree and is rejected. Guards the per-level cascade recomputation.
    function test_RevertWhen_timeout_wrongCascadeLevelSibling() public {
        bytes32 levelZeroHash = _emptySubtreeCascade(1)[0];
        bytes32[] memory siblings = new bytes32[](2);
        siblings[0] = levelZeroHash;
        siblings[1] = levelZeroHash; // wrong: level 1 requires keccak(zeros[0] || zeros[0])

        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: siblings
        });
        _importRoot(aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofNotLastBatchInRoot.selector, 1, levelZeroHash));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ verifyTimeoutAbsence — reverts ============

    /// @dev Boundary: a settlement-layer interop root created exactly AT the deadline is not strictly
    /// after it — the stale/genesis-root guard (an in-time snapshot proves nothing about the deadline).
    function test_RevertWhen_timeout_interopRootAtDeadline() public {
        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, DEADLINE, aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofInteropRootNotAfterDeadline.selector, uint256(DEADLINE), DEADLINE));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev A missing settlement interop root has an unset timestamp that reads as 0 and is rejected.
    /// The branch is defense-in-depth, unreachable through the real verifier by construction: that
    /// verifier accepts the proof only at a non-zero `interopRoots(slChainId, slBlock).root`, the same
    /// key the library reads the timestamp from, and `L2InteropRootStorage` rejects a zero root and a
    /// zero timestamp. That is why this one case stubs the verifier: it keeps the branch covered.
    function test_RevertWhen_timeout_missingSettlementInteropRoot() public {
        // The only verifier stub in these suites; see the @dev above.
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared.selector),
            abi.encode(true)
        );
        (ImtProof memory absence, ) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProofSettlementLayerInteropRootNotImported.selector,
                SETTLEMENT_LAYER_CHAIN_ID,
                SL_BLOCK
            )
        );
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev In-time batch that is NOT the chain's last inside the settlement-layer interop root: a
    /// populated right sibling means a later batch — which may contain the commit — exists, so rejected.
    function test_RevertWhen_timeout_inTimeBatchNotLastInRoot() public {
        bytes32 populatedSibling = keccak256("populated-right-subtree");
        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = populatedSibling;

        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: siblings
        });
        _importRoot(aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofNotLastBatchInRoot.selector, 0, populatedSibling));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Boundary of the branch validation: a batch settled exactly AT the deadline is in time
    /// (`t <= deadline`, matching {verifyInclusion}'s clock), so the begin branch — which requires a
    /// strictly late batch — must reject it. Where the next test pins `t < deadline`, this one
    /// pins the `t == deadline` edge, where begin-branch absence would contradict a same-batch
    /// finalization. The proof authenticates the begin root, so only the branch check rejects it.
    function test_RevertWhen_timeout_beginBranchWithBatchAtDeadline() public {
        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importRoot(aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofTimeoutBranchMismatch.selector, true, uint256(DEADLINE), DEADLINE));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The declared branch must match the authenticated inclusion time: the begin root proves
    /// nothing for an in-time batch (its begin state predates the deadline moment). The proof
    /// authenticates the begin root, so only the branch check rejects it.
    function test_RevertWhen_timeout_beginBranchWithInTimeBatch() public {
        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importRoot(aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofTimeoutBranchMismatch.selector, true, uint256(DEADLINE) - 1, DEADLINE)
        );
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev ...and the end root is paired exclusively with the in-time last-batch branch: a late
    /// batch must use its begin root (which needs no last-batch property). The proof authenticates
    /// the end root, so only the branch check rejects it.
    function test_RevertWhen_timeout_endBranchWithLateBatch() public {
        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importRoot(aggregatedRoot);
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

        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: siblings
        });
        _importRoot(aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The timeout path rejects a final-node proof too, though the real verifier accepts it against
    /// the source chain's own imported batch root.
    function test_RevertWhen_timeout_missingSettlementLayerBatch() public {
        (ImtProof memory absence, ) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        bytes32 chainBatchRoot;
        (absence.settlementProof, chainBatchRoot) = _finalSettlementProof({
            _imtRoot: absence.chainImtRoot,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _otherImtRoot: OTHER_IMT_ROOT
        });
        _importInteropRoot(SOURCE_CHAIN_ID, BATCH_N, uint256(DEADLINE) + 1, chainBatchRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(ProofMissingSettlementLayerBatch.selector, SOURCE_CHAIN_ID, BATCH_N));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    function test_RevertWhen_timeout_settlementLayerMismatch() public {
        uint256 proofSl = SETTLEMENT_LAYER_CHAIN_ID + 1;
        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: proofSl,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        // Authentic on its own settlement layer, which is not the flow's.
        _importInteropRoot(proofSl, SL_BLOCK, uint256(DEADLINE) + 1, aggregatedRoot);
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofSettlementLayerMismatch.selector, SETTLEMENT_LAYER_CHAIN_ID, proofSl)
        );
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The settlement root the proof reconstructs was never imported, so the real verifier rejects it.
    function test_RevertWhen_timeout_imtRootInclusionFails() public {
        (ImtProof memory absence, ) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
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
    /// The inclusion half runs end-to-end (real aggregation); the illegitimate absence half
    /// forward-computes a begin-root proof from the real tree's predecessor leaf and imports its root.
    function test_includedValueCannotBeProvenAbsent() public {
        // Sanity: the committed value verifies as included in time (real, unmocked).
        ImtProof memory inclusion = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, DEADLINE - 1);
        _expectRootAuthentication(inclusion, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(inclusion, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);

        // Forge an absence proof from the committed value's true predecessor leaf, against a late batch
        // inside the post-deadline settlement-layer interop root.
        (bytes32[] memory settlementProof, bytes32 aggregatedRoot) = _settlementProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _imtRoot: tree.root(),
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _otherImtRoot: OTHER_IMT_ROOT,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: uint256(DEADLINE) + 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importRoot(aggregatedRoot);
        uint256 predIndex = _predecessorIndexOf(committedValue);
        ImtProof memory absence = ImtProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_N,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: true,
            settlementProof: settlementProof,
            leaf: tree.leafAt(predIndex),
            imtLeafIndex: predIndex,
            imtProof: tree.merklePath(predIndex)
        });

        // The predecessor's `nextValue == committedValue`, so non-inclusion is rejected by the IMT engine.
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafNextTooSmall.selector, committedValue, committedValue));
        proofLib.verifyTimeoutAbsence(absence, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev The begin/end leaf binding the end branch's soundness rests on
    /// ({protocol-docs/atomicity/proofs.md#soundness}): an in-time batch commits the value, so its begin
    /// root excludes it, its end root includes it, and the leg is finalizable from that batch. Absence
    /// from the begin root then proves nothing: the begin branch is closed by the clock, and the end
    /// branch by the verifier, because the proof words authenticate the begin root as leaf 2 only.
    function test_RevertWhen_timeout_endBranchPresentsBeginRoot() public {
        uint256 batchCommit = AtomicFlowFixtures.commitValue(keccak256("flowC"), keccak256("bundleC"));
        // Absence data against the batch-begin state, read before the batch commits the value.
        uint256 lowIndex = _lowNullifierIndex(batchCommit);
        ImtProof memory absence = ImtProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_N,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: true,
            settlementProof: new bytes32[](0),
            leaf: tree.leafAt(lowIndex),
            imtLeafIndex: lowIndex,
            imtProof: tree.merklePath(lowIndex)
        });
        uint256 commitIndex = _insertCommit(batchCommit);

        bytes32 aggregatedRoot;
        (absence.settlementProof, aggregatedRoot) = _settlementProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _imtRoot: absence.chainImtRoot,
            _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            _otherImtRoot: tree.root(),
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importRoot(aggregatedRoot);

        // Finalizable: the same batch's end root includes the commit.
        {
            (bytes32[] memory endLeafProof, bytes32 sameBatchRoot) = _settlementProof({
                _sourceChainId: SOURCE_CHAIN_ID,
                _batchNumber: BATCH_N,
                _imtRoot: tree.root(),
                _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
                _otherImtRoot: absence.chainImtRoot,
                _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
                _slBlock: SL_BLOCK,
                _l1Timestamp: DEADLINE - 1,
                _batchLeafProofMask: 0,
                _batchLeafSiblings: new bytes32[](0)
            });
            assertEq(sameBatchRoot, aggregatedRoot, "both IMT roots are leaves of the same batch");
            ImtProof memory inclusion = ImtProof({
                sourceChainId: SOURCE_CHAIN_ID,
                batchNumber: BATCH_N,
                chainImtRoot: tree.root(),
                provesAgainstBeginRoot: false,
                settlementProof: endLeafProof,
                leaf: tree.leafAt(commitIndex),
                imtLeafIndex: commitIndex,
                imtProof: tree.merklePath(commitIndex)
            });
            _expectRootAuthentication(inclusion, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
            proofLib.verifyInclusion(inclusion, batchCommit, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
        }

        // The proof authenticates the begin root as leaf 2, where the in-time batch fails the clock...
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofTimeoutBranchMismatch.selector, true, uint256(DEADLINE) - 1, DEADLINE)
        );
        proofLib.verifyTimeoutAbsence(absence, batchCommit, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);

        // ...and not as leaf 3, so the end branch cannot read it as the batch's final state.
        absence.provesAgainstBeginRoot = false;
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(ProofImtRootInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_N, absence.chainImtRoot)
        );
        proofLib.verifyTimeoutAbsence(absence, batchCommit, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    // ============ fuzz ============

    /// @dev Across the deadline boundary, an inclusion proof passes iff `l1Timestamp <= deadline`. Each
    /// run forward-computes the proof for the fuzzed timestamp and imports its root.
    function testFuzz_verifyInclusion_deadlineBoundary(uint64 _l1Timestamp, uint64 _deadline) public {
        (ImtProof memory proof, bytes32 aggregatedRoot) = _inclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _leafIndex: committedIndex,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: _l1Timestamp
        });
        _importRoot(aggregatedRoot);
        if (uint256(_l1Timestamp) > uint256(_deadline)) {
            vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, uint256(_l1Timestamp), _deadline));
        }
        _expectRootAuthentication(proof, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
        proofLib.verifyInclusion(proof, committedValue, _deadline, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @dev Timeout passes iff the settlement-layer interop root is strictly after the deadline;
    /// `T <= deadline` must FAIL regardless of the batch's own timestamp (stale/genesis-root guard).
    /// Both branches (late batch -> begin root, in-time last batch -> end root) are fuzzed, each proof
    /// built for the branch an honest prover declares against the fuzzed deadline.
    function testFuzz_verifyTimeoutAbsence_interopRootWindow(
        uint64 _batchTimestamp,
        uint64 _interopRootTimestamp,
        uint64 _deadline
    ) public {
        vm.assume(_interopRootTimestamp != 0); // 0 == "never seeded"; covered by its own test
        uint256 imtRootLeafIndex = uint256(_batchTimestamp) > uint256(_deadline)
            ? ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX
            : ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX;
        (ImtProof memory absence, bytes32 aggregatedRoot) = _nonInclusionProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _absentValue: absentValue,
            _imtRootLeafIndex: imtRootLeafIndex,
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: _batchTimestamp,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        _importInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, _interopRootTimestamp, aggregatedRoot);
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
