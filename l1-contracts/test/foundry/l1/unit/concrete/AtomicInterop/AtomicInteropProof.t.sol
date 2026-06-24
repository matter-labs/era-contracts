// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {ImtInclusionProof, ImtTimeoutProof, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    AtomicProofChainMismatch,
    AtomicRootMessageInclusionFailed,
    AtomicMissingSettlementLayerAnchor,
    AtomicDeadlineExceeded,
    AtomicDeadlineNotExceeded,
    AtomicInclusionFailed,
    AtomicNonInclusionFailed
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IMTLeafValueMismatch, IMTLowLeafNextTooSmall} from "contracts/common/L1ContractErrors.sol";

import {
    AtomicInteropProofHarness,
    InteropCommitmentTreeHarness,
    MockMessageVerification,
    slProofBytes,
    finalProofBytes
} from "./AtomicInteropTestUtils.sol";

/// @title Unit tests for the full-reuse {AtomicInteropProof} message-verification library.
/// @notice The message verifier is a {MockMessageVerification} (the message → interop-root authentication
/// is the existing, separately-tested pipeline). The settlement-layer block is carried in a minimal but
/// format-valid proof ({slProofBytes}) that the REAL {MessageHashing._getProofData} parses — so these
/// tests exercise the genuine deadline split and IMT membership against a real {IndexedMerkleTree}.
contract AtomicInteropProofTest is Test {
    AtomicInteropProofHarness internal harness;
    MockMessageVerification internal verifier;
    InteropCommitmentTreeHarness internal imt;

    address internal constant COMMITMENT_TREE = address(0x10012);
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant SL_CHAIN_ID = 506;
    uint256 internal constant BATCH_NUMBER = 1;

    function setUp() public {
        harness = new AtomicInteropProofHarness();
        verifier = new MockMessageVerification();
        imt = new InteropCommitmentTreeHarness();
        imt.setup();
    }

    /*//////////////////////////////////////////////////////////////
                              INCLUSION
    //////////////////////////////////////////////////////////////*/

    function test_VerifyInclusion_happyPath() public {
        uint256 commit = _commit("flow-a", "spec-a");
        imt.insert(commit, 0);
        ImtInclusionProof memory proof = _inclusion(commit, SOURCE_CHAIN_ID, 900);

        // Snapshot block (900) <= deadline (1000): committed in time. Also checks slChainId is surfaced.
        uint256 slChainId = harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, commit, 1000);
        assertEq(slChainId, SL_CHAIN_ID, "settlement-layer chain id surfaced for cross-leg checks");
    }

    function test_RevertWhen_InclusionDeadlineExceeded() public {
        uint256 commit = _commit("flow-c", "spec-c");
        imt.insert(commit, 0);
        ImtInclusionProof memory proof = _inclusion(commit, SOURCE_CHAIN_ID, 1001);

        vm.expectRevert(abi.encodeWithSelector(AtomicDeadlineExceeded.selector, uint256(1001), uint256(1000)));
        harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, commit, 1000);
    }

    function test_RevertWhen_InclusionChainMismatch() public {
        uint256 commit = _commit("flow-d", "spec-d");
        imt.insert(commit, 0);
        ImtInclusionProof memory proof = _inclusion(commit, SOURCE_CHAIN_ID, 900);

        uint256 wrongChain = SOURCE_CHAIN_ID + 1;
        vm.expectRevert(abi.encodeWithSelector(AtomicProofChainMismatch.selector, wrongChain, SOURCE_CHAIN_ID));
        harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, wrongChain, commit, 1000);
    }

    function test_RevertWhen_InclusionMessageNotProven() public {
        uint256 commit = _commit("flow-e", "spec-e");
        imt.insert(commit, 0);
        ImtInclusionProof memory proof = _inclusion(commit, SOURCE_CHAIN_ID, 900);

        verifier.setResult(false); // the message verifier rejects the root message
        vm.expectRevert(
            abi.encodeWithSelector(AtomicRootMessageInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_NUMBER)
        );
        harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, commit, 1000);
    }

    function test_RevertWhen_InclusionFinalProofNodeHasNoAnchor() public {
        uint256 commit = _commit("flow-f", "spec-f");
        imt.insert(commit, 0);
        ImtInclusionProof memory proof = _inclusion(commit, SOURCE_CHAIN_ID, 900);
        proof.messageProof = finalProofBytes(); // single-level proof carries no settlement-layer block

        vm.expectRevert(
            abi.encodeWithSelector(AtomicMissingSettlementLayerAnchor.selector, SOURCE_CHAIN_ID, BATCH_NUMBER)
        );
        harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, commit, 1000);
    }

    function test_RevertWhen_InclusionTamperedImtProof() public {
        uint256 commit = _commit("flow-g", "spec-g");
        imt.insert(commit, 0);
        ImtInclusionProof memory proof = _inclusion(commit, SOURCE_CHAIN_ID, 900);
        assertGt(proof.imtProof.length, 0);
        proof.imtProof[0] = bytes32(uint256(proof.imtProof[0]) ^ 1); // path no longer reconstructs the root

        vm.expectRevert(abi.encodeWithSelector(AtomicInclusionFailed.selector, proof.chainImtRoot, commit));
        harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, commit, 1000);
    }

    function test_RevertWhen_InclusionWrongCommitValue() public {
        uint256 committed = _commit("flow-h", "spec-h");
        imt.insert(committed, 0);
        ImtInclusionProof memory proof = _inclusion(committed, SOURCE_CHAIN_ID, 900);

        // The leaf proves `committed`, not `other`, so the IMT value binding rejects it.
        uint256 other = _commit("flow-h", "spec-other");
        vm.expectRevert(abi.encodeWithSelector(IMTLeafValueMismatch.selector, other, committed));
        harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, other, 1000);
    }

    /*//////////////////////////////////////////////////////////////
                               TIMEOUT
    //////////////////////////////////////////////////////////////*/

    function test_VerifyTimeout_happyPath() public {
        imt.insert(_commit("flow-x", "present-1"), 0);
        imt.insert(_commit("flow-x", "present-2"), 0);

        uint256 absent = _commit("flow-x", "never");
        ImtTimeoutProof memory proof = _timeout(absent, SOURCE_CHAIN_ID, 1001);

        // slBlock (1001) > deadline (1000): leg can no longer be committed in time.
        uint256 slChainId = harness.verifyTimeout(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, absent, 1000);
        assertEq(slChainId, SL_CHAIN_ID, "settlement-layer chain id surfaced");
    }

    function test_RevertWhen_TimeoutDeadlineNotExceeded() public {
        imt.insert(_commit("flow-y", "present"), 0);
        uint256 absent = _commit("flow-y", "never");
        ImtTimeoutProof memory proof = _timeout(absent, SOURCE_CHAIN_ID, 1000);

        // slBlock == deadline must fail (relation is strict `>`).
        vm.expectRevert(abi.encodeWithSelector(AtomicDeadlineNotExceeded.selector, uint256(1000), uint256(1000)));
        harness.verifyTimeout(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, absent, 1000);
    }

    function test_RevertWhen_TimeoutOnCommittedValue() public {
        // A committed value cannot be proven absent — the safety property that blocks refunding a leg
        // that actually settled. A present value has no valid low nullifier, so the best a prover can do is
        // point at the sentinel leaf (index 0); its `nextValue` is the smallest inserted value, which is
        // `<= committed`, so `IndexedMerkleTree.verifyNonInclusion` rejects with `IMTLowLeafNextTooSmall`.
        uint256 committed = _commit("flow-z", "committed");
        uint256 neighbour = _commit("flow-z", "neighbour");
        imt.insert(committed, 0);
        imt.insert(neighbour, 0);
        ImtTimeoutProof memory proof = _timeoutAt(committed, SOURCE_CHAIN_ID, 1001, 0);

        // The sentinel's nextValue is the smallest inserted value (<= committed), so the bracket rejects.
        uint256 sentinelNext = committed < neighbour ? committed : neighbour;
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafNextTooSmall.selector, sentinelNext, committed));
        harness.verifyTimeout(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, committed, 1000);
    }

    function test_RevertWhen_TimeoutChainMismatch() public {
        imt.insert(_commit("flow-w", "present"), 0);
        uint256 absent = _commit("flow-w", "never");
        ImtTimeoutProof memory proof = _timeout(absent, SOURCE_CHAIN_ID, 1001);

        uint256 wrongChain = SOURCE_CHAIN_ID + 9;
        vm.expectRevert(abi.encodeWithSelector(AtomicProofChainMismatch.selector, wrongChain, SOURCE_CHAIN_ID));
        harness.verifyTimeout(proof, verifier, COMMITMENT_TREE, wrongChain, absent, 1000);
    }

    /*//////////////////////////////////////////////////////////////
                            COMMIT VALUE
    //////////////////////////////////////////////////////////////*/

    function test_CommitValue_matchesTaggedEncoding() public view {
        bytes32 flowId = keccak256("flow");
        bytes32 specHash = keccak256("spec");
        uint256 expected = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, specHash)));
        assertEq(harness.commitValue(flowId, specHash), expected, "matches the domain-tagged encoding");
        // Domain separation: the tag makes the commit value distinct from the untagged hash of the same inputs.
        assertTrue(
            harness.commitValue(flowId, specHash) != uint256(keccak256(abi.encode(flowId, specHash))),
            "domain-separated from the untagged hash"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_InclusionDeadlineSplit(uint64 _slBlock, uint64 _deadline) public {
        uint256 commit = _commit("fuzz-incl", "leg");
        imt.insert(commit, 0);
        ImtInclusionProof memory proof = _inclusion(commit, SOURCE_CHAIN_ID, _slBlock);

        if (_slBlock <= _deadline) {
            harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, commit, _deadline);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(AtomicDeadlineExceeded.selector, uint256(_slBlock), uint256(_deadline))
            );
            harness.verifyInclusion(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, commit, _deadline);
        }
    }

    function testFuzz_TimeoutDeadlineSplit(uint64 _slBlock, uint64 _deadline) public {
        imt.insert(_commit("fuzz-to", "present"), 0);
        uint256 absent = _commit("fuzz-to", "absent");
        ImtTimeoutProof memory proof = _timeout(absent, SOURCE_CHAIN_ID, _slBlock);

        if (_slBlock > _deadline) {
            harness.verifyTimeout(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, absent, _deadline);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(AtomicDeadlineNotExceeded.selector, uint256(_slBlock), uint256(_deadline))
            );
            harness.verifyTimeout(proof, verifier, COMMITMENT_TREE, SOURCE_CHAIN_ID, absent, _deadline);
        }
    }

    function testFuzz_SlChainIdRoundTrips(uint256 _slBlock, uint256 _slChainId) public {
        _slBlock = bound(_slBlock, 0, type(uint128).max - 1);
        _slChainId = bound(_slChainId, 1, type(uint64).max);

        uint256 commit = _commit("fuzz-sl", "leg");
        imt.insert(commit, 0);
        uint256 idx = imt.indexOfValue(commit);
        ImtInclusionProof memory proof = ImtInclusionProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_NUMBER,
            chainImtRoot: imt.root(),
            messageTxNumberInBatch: 0,
            messageIndex: 0,
            messageProof: slProofBytes(_slBlock, _slChainId),
            leaf: imt.leafAt(idx),
            imtLeafIndex: idx,
            imtProof: imt.merklePath(idx)
        });

        uint256 returnedSlChainId = harness.verifyInclusion(
            proof,
            verifier,
            COMMITMENT_TREE,
            SOURCE_CHAIN_ID,
            commit,
            type(uint256).max
        );
        assertEq(returnedSlChainId, _slChainId);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _commit(string memory _flow, string memory _spec) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, keccak256(bytes(_flow)), keccak256(bytes(_spec)))));
    }

    /// @dev Inclusion proof for an already-inserted `_commit`, carrying `_slBlock` in its message proof.
    function _inclusion(
        uint256 _commitValue,
        uint256 _sourceChainId,
        uint256 _slBlock
    ) internal view returns (ImtInclusionProof memory) {
        uint256 idx = imt.indexOfValue(_commitValue);
        return
            ImtInclusionProof({
                sourceChainId: _sourceChainId,
                batchNumber: BATCH_NUMBER,
                chainImtRoot: imt.root(),
                messageTxNumberInBatch: 0,
                messageIndex: 0,
                messageProof: slProofBytes(_slBlock, SL_CHAIN_ID),
                leaf: imt.leafAt(idx),
                imtLeafIndex: idx,
                imtProof: imt.merklePath(idx)
            });
    }

    /// @dev Timeout (non-inclusion) proof for an absent `_commit`, carrying `_slBlock` in its message proof.
    function _timeout(
        uint256 _commitValue,
        uint256 _sourceChainId,
        uint256 _slBlock
    ) internal view returns (ImtTimeoutProof memory) {
        return _timeoutAt(_commitValue, _sourceChainId, _slBlock, imt.lowNullifierIndex(_commitValue));
    }

    /// @dev Timeout proof using an explicit low-leaf index — lets tests feed a deliberately invalid low
    /// leaf (e.g. for a present value, which has no valid low nullifier) and assert the library rejects it.
    function _timeoutAt(
        uint256,
        uint256 _sourceChainId,
        uint256 _slBlock,
        uint256 _lowIdx
    ) internal view returns (ImtTimeoutProof memory) {
        return
            ImtTimeoutProof({
                sourceChainId: _sourceChainId,
                batchNumber: BATCH_NUMBER,
                chainImtRoot: imt.root(),
                messageTxNumberInBatch: 0,
                messageIndex: 0,
                messageProof: slProofBytes(_slBlock, SL_CHAIN_ID),
                lowLeaf: imt.leafAt(_lowIdx),
                lowLeafIndex: _lowIdx,
                imtProof: imt.merklePath(_lowIdx)
            });
    }
}
