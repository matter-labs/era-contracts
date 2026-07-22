// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {
    ProofImtRootInclusionFailed,
    ProofInvalidChainBatchRootDepth
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {L2_MESSAGE_VERIFICATION_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice The highest-risk integration seam of the atomic proof stack, tested end-to-end with NO
/// verifier mock: `AtomicInteropProof` -> the REAL `L2MessageVerification` -> a REAL imported interop
/// root in `L2InteropRootStorage`.
///
/// Every other atomic proof test selector-mocks `proveL2LeafInclusionShared` (see
/// {AtomicInteropProofBuilder}) — appropriate for isolating the library's own branches, but it means
/// the two-hop recursive Merkle authentication and the terminal `interopRoots` check never actually
/// run against the library's proof bytes. Here we deploy the real verifier and build a genuine
/// settlement proof whose two hops reconstruct, via the exact library functions the verifier uses, an
/// aggregation root we then import for real. The proof therefore has to authenticate for the test to
/// pass, and tampering with any authenticated word breaks it.
///
/// Construction is forward: we pick the Merkle siblings, compute each intermediate root with
/// {Merkle.calculateRootMemory} / {MessageHashing} exactly as `MessageHashing._getProofData` will, and
/// seed the terminal aggregation root — so the round trip is guaranteed by construction while the
/// verifier's real math is what actually checks it. The chain-batch-root hop is built with the real
/// {ChainBatchRootTree} layout, so `batchSettlementRoot` is a faithful chain batch root.
contract AtomicInteropProofRealVerificationTest is AtomicInteropProofBuilder {
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1; // L1
    uint256 internal constant BATCH_N = 100;
    uint256 internal constant SL_BLOCK = 555;

    uint256 internal committedValue;
    uint256 internal committedIndex;
    uint256 internal absentValue;

    function setUp() public {
        _setUpAtomicFixtures();
        // Deploy the REAL L2MessageVerification at its canonical address — deliberately NOT calling
        // `_mockVerifier`, so `AtomicInteropProof` authenticates through the production code path.
        deployCodeTo("L2MessageVerification.sol:L2MessageVerification", L2_MESSAGE_VERIFICATION_ADDR);

        committedValue = _commitValue(keccak256("flowA"), keccak256("bundleA"));
        committedIndex = _insertCommit(committedValue);
        absentValue = _commitValue(keccak256("flowB"), keccak256("bundleB"));
    }

    // ------------------------------------------------------------------------------------------------
    // Real settlement-proof builder (forward-computed, no mocks)
    // ------------------------------------------------------------------------------------------------

    /// @dev Builds a genuine two-hop settlement proof for `_imtRoot` as chain-batch-root leaf
    /// `_imtRootLeafIndex` (2=begin / 3=end) and returns it alongside the aggregation root the verifier
    /// will require in `interopRoots[SETTLEMENT_LAYER_CHAIN_ID][SL_BLOCK]`. Single-leaf chain tree and
    /// single-leaf aggregation tree (empty sibling paths), which keeps the batch the chain's last one
    /// (needed by the timeout end-branch) and the arithmetic trivial without weakening the seam: the
    /// real verifier still recomputes every hop.
    function _buildRealSettlementProof(
        bytes32 _imtRoot,
        uint256 _imtRootLeafIndex,
        uint256 _l1Timestamp
    ) internal pure returns (bytes32[] memory proof, bytes32 aggRoot) {
        // --- hop 1: reconstruct the chain batch root from the IMT-root leaf ---
        // Faithful ChainBatchRootTree layout: the sibling of the begin/end IMT leaf at level 0 is the
        // other IMT snapshot, at level 1 keccak(logsRoot=0 || multichainRoot=0), at level 2 the
        // reserved right subtree. `Merkle.calculateRootMemory(path, index, leaf)` with index == leaf
        // index then reproduces `ChainBatchRootTree.compute` exactly.
        bytes32 otherImtSnapshot = keccak256("the other IMT snapshot");
        bytes32[] memory topSiblings = new bytes32[](ChainBatchRootTree.TREE_DEPTH);
        topSiblings[0] = otherImtSnapshot;
        topSiblings[1] = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        topSiblings[2] = ChainBatchRootTree.RESERVED_SUBTREE_NODE;
        bytes32 batchSettlementRoot = Merkle.calculateRootMemory(topSiblings, _imtRootLeafIndex, _imtRoot);

        // --- hop 1: batch leaf -> chain-id leaf (single-leaf chain tree) ---
        bytes32 batchLeaf = MessageHashing.batchLeafHash(batchSettlementRoot, BATCH_N, _l1Timestamp);
        bytes32[] memory noBatchLeafSiblings = new bytes32[](0);
        bytes32 chainIdRoot = Merkle.calculateRootMemory(noBatchLeafSiblings, 0, batchLeaf);
        bytes32 chainIdLeaf = MessageHashing.chainIdLeafHash(chainIdRoot, SOURCE_CHAIN_ID);

        // --- hop 2: chain-id leaf -> aggregation root (single-leaf aggregation tree) ---
        bytes32[] memory noAggSiblings = new bytes32[](0);
        aggRoot = Merkle.calculateRootMemory(noAggSiblings, 0, chainIdLeaf);

        // --- assemble the proof bytes (see MessageHashing._getProofData word layout) ---
        // hop1: [meta1][3 top siblings][l1Timestamp][batchLeafMask=0][slPacked][slChainId]
        // hop2: [meta2(final)] — single-leaf aggregation, so no siblings follow
        // Word layout below: meta1(1) + top siblings(TREE_DEPTH) + l1Timestamp(1) + batchLeafMask(1) +
        // slPacked(1) + slChainId(1) + meta2(1).
        proof = new bytes32[](ChainBatchRootTree.TREE_DEPTH + 6);
        proof[0] = _composeMetadata({
            _logLeafProofLen: ChainBatchRootTree.TREE_DEPTH,
            _batchLeafProofLen: 0,
            _finalProofNode: false
        });
        proof[1] = topSiblings[0];
        proof[2] = topSiblings[1];
        proof[3] = topSiblings[2];
        proof[4] = bytes32(_l1Timestamp);
        proof[5] = bytes32(uint256(0)); // batchLeafProofMask
        proof[6] = bytes32(SL_BLOCK << 128); // (slBlock << 128) | slBatchRootMask(0)
        proof[7] = bytes32(SETTLEMENT_LAYER_CHAIN_ID);
        proof[8] = _composeMetadata({_logLeafProofLen: 0, _batchLeafProofLen: 0, _finalProofNode: true});
    }

    /// @dev Builds a full `ImtProof` with a real settlement proof and imports the resulting aggregation
    /// root into the real `L2InteropRootStorage` at (SL, SL_BLOCK) with `_interopRootTimestamp`.
    function _realInclusionProof(uint256 _l1Timestamp) internal returns (ImtProof memory p) {
        (bytes32[] memory settlementProof, bytes32 aggRoot) = _buildRealSettlementProof(
            tree.root(),
            ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _l1Timestamp
        );
        _importRoot(aggRoot, _l1Timestamp);
        p = ImtProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_N,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: false,
            settlementProof: settlementProof,
            leaf: tree.leafAt(committedIndex),
            imtLeafIndex: committedIndex,
            imtProof: tree.merklePath(committedIndex)
        });
    }

    /// @dev Imports `_root` into the real L2InteropRootStorage at (SL, SL_BLOCK) with a creation
    /// timestamp derived from the batch time (post-deadline for the timeout tests).
    function _importRoot(bytes32 _root, uint256) internal {
        _seedSettlementLayerInteropRootWithValue(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, uint256(DEADLINE) + 5, _root);
    }

    // ============ real inclusion ============

    /// @notice A commit value that is genuinely in the IMT, with a settlement proof that genuinely
    /// authenticates against a genuinely imported aggregation root, passes `verifyInclusion` through the
    /// real verifier — no mock anywhere in the path.
    function test_verifyInclusion_realVerifier_happy() public {
        ImtProof memory proof = _realInclusionProof(DEADLINE - 1);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @notice Tampering with an authenticated proof word (a chain-batch-root sibling) makes the real
    /// two-hop reconstruction land on a different aggregation root than the imported one, so the real
    /// verifier returns false and the library surfaces `ProofImtRootInclusionFailed`.
    function test_verifyInclusion_realVerifier_RevertWhen_topSiblingTampered() public {
        ImtProof memory proof = _realInclusionProof(DEADLINE - 1);
        proof.settlementProof[1] = bytes32(uint256(proof.settlementProof[1]) ^ 1); // flip one bit

        vm.expectRevert(
            abi.encodeWithSelector(ProofImtRootInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_N, proof.chainImtRoot)
        );
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @notice Tampering with the metadata's chain-batch-root depth is caught before any hashing: the
    /// leaf-to-batch-root section must be exactly {ChainBatchRootTree.TREE_DEPTH} hops.
    function test_verifyInclusion_realVerifier_RevertWhen_depthTampered() public {
        ImtProof memory proof = _realInclusionProof(DEADLINE - 1);
        uint256 wrongDepth = ChainBatchRootTree.TREE_DEPTH + 1;
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

    // ============ real timeout ============

    /// @notice The timeout begin-branch through the real verifier: an absent commit value, proven
    /// non-included against the batch-BEGIN IMT root of a late batch, authenticated against a genuinely
    /// imported post-deadline aggregation root, passes `verifyTimeoutAbsence`. The single-leaf chain
    /// tree makes the batch trivially the chain's last, and the begin branch needs no last-batch check.
    function test_verifyTimeoutAbsence_realVerifier_beginBranch_happy() public {
        uint256 lateTimestamp = uint256(DEADLINE) + 1;
        (bytes32[] memory settlementProof, bytes32 aggRoot) = _buildRealSettlementProof(
            tree.root(),
            ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            lateTimestamp
        );
        _importRoot(aggRoot, lateTimestamp);

        uint256 lowIndex = _lowNullifierIndex(absentValue);
        ImtProof memory absence = ImtProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_N,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: true,
            settlementProof: settlementProof,
            leaf: tree.leafAt(lowIndex),
            imtLeafIndex: lowIndex,
            imtProof: tree.merklePath(lowIndex)
        });

        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }
}
