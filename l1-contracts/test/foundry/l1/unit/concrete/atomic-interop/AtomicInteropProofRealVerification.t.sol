// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {ProofNotLastBatchInRoot} from "contracts/atomic-interop/AtomicInteropErrors.sol";

/// @notice Exercises a non-leftmost batch-leaf proof through the real `L2MessageVerification` and
/// imported `L2InteropRootStorage` root. The shared live-tree fixtures only produce mask-zero paths,
/// so this suite forward-computes a right-child last-leaf path and its invalid counterpart.
contract AtomicInteropProofRealVerificationTest is AtomicInteropProofBuilder {
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1; // L1
    uint256 internal constant BATCH_N = 100;
    uint256 internal constant SL_BLOCK = 555;

    uint256 internal absentValue;

    function setUp() public {
        _setUpAtomicFixtures(); // deploys the real verifier; no test here ever calls _mockVerifier
        absentValue = _commitValue(keccak256("flowB"), keccak256("bundleB"));
    }

    // ------------------------------------------------------------------------------------------------
    // Real settlement-proof builder (forward-computed, no mocks)
    // ------------------------------------------------------------------------------------------------

    /// @dev General builder: same two-hop reconstruction, but with a caller-chosen batch-leaf position
    /// (`_batchLeafMask` + `_batchLeafSiblings`) inside the chain's batch tree — used to exercise the
    /// timeout end-branch last-batch check against a non-leftmost (right-child) last leaf through the
    /// real verifier.
    function _buildRealSettlementProofMasked(
        bytes32 _imtRoot,
        uint256 _imtRootLeafIndex,
        uint256 _l1Timestamp,
        uint256 _batchLeafMask,
        bytes32[] memory _batchLeafSiblings
    ) internal pure returns (bytes32[] memory proof, bytes32 aggRoot) {
        // --- hop 1: reconstruct the chain batch root from the IMT-root leaf ---
        // Faithful ChainBatchRootTree layout: the sibling of the begin/end IMT leaf at level 0 is the
        // other IMT snapshot, at level 1 keccak(logsRoot=0 || multichainRoot=0), at level 2 the
        // reserved right subtree. `Merkle.calculateRootMemory(path, index, leaf)` with index == leaf
        // index then reproduces `ChainBatchRootTree.compute` exactly.
        bytes32[] memory topSiblings = new bytes32[](ChainBatchRootTree.TREE_DEPTH);
        topSiblings[0] = keccak256("the other IMT snapshot");
        topSiblings[1] = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        topSiblings[2] = ChainBatchRootTree.RESERVED_SUBTREE_NODE;
        bytes32 batchSettlementRoot = Merkle.calculateRootMemory(topSiblings, _imtRootLeafIndex, _imtRoot);

        // --- hop 1: batch leaf -> chain-id leaf (chain tree with the given batch-leaf path) ---
        bytes32 batchLeaf = MessageHashing.batchLeafHash(batchSettlementRoot, BATCH_N, _l1Timestamp);
        bytes32 chainIdRoot = Merkle.calculateRootMemory(_batchLeafSiblings, _batchLeafMask, batchLeaf);
        bytes32 chainIdLeaf = MessageHashing.chainIdLeafHash(chainIdRoot, SOURCE_CHAIN_ID);

        // --- hop 2: chain-id leaf -> aggregation root (single-leaf aggregation tree) ---
        aggRoot = Merkle.calculateRootMemory(new bytes32[](0), 0, chainIdLeaf);

        // --- assemble the proof bytes (see MessageHashing._getProofData word layout) ---
        // hop1: [meta1][3 top siblings][l1Timestamp][batchLeafMask][k batch siblings][slPacked][slChainId]
        // hop2: [meta2(final)] — single-leaf aggregation, so no siblings follow
        uint256 k = _batchLeafSiblings.length;
        proof = new bytes32[](ChainBatchRootTree.TREE_DEPTH + 6 + k);
        proof[0] = _composeMetadata({
            _logLeafProofLen: ChainBatchRootTree.TREE_DEPTH,
            _batchLeafProofLen: k,
            _finalProofNode: false
        });
        proof[1] = topSiblings[0];
        proof[2] = topSiblings[1];
        proof[3] = topSiblings[2];
        proof[4] = bytes32(_l1Timestamp);
        proof[5] = bytes32(_batchLeafMask);
        for (uint256 i = 0; i < k; ++i) {
            proof[6 + i] = _batchLeafSiblings[i];
        }
        proof[6 + k] = bytes32(SL_BLOCK << 128); // (slBlock << 128) | slBatchRootMask(0)
        proof[7 + k] = bytes32(SETTLEMENT_LAYER_CHAIN_ID);
        proof[8 + k] = _composeMetadata({_logLeafProofLen: 0, _batchLeafProofLen: 0, _finalProofNode: true});
    }

    /// @dev The creation time imported for the aggregation root. Post-deadline so the timeout tests'
    /// `T > deadline` guard holds; the inclusion test does not read it.
    uint256 internal constant INTEROP_ROOT_TIMESTAMP = uint256(DEADLINE) + 5;

    /// @dev Imports `_root` into the real L2InteropRootStorage at (SL, SL_BLOCK) with a post-deadline
    /// creation timestamp ({INTEROP_ROOT_TIMESTAMP}).
    function _importRoot(bytes32 _root) internal {
        _seedSettlementLayerInteropRootWithValue(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, INTEROP_ROOT_TIMESTAMP, _root);
    }

    /// @dev A batch-leaf path for a RIGHT-child last leaf at mask `0b01` in a 2-level chain tree: level
    /// 0 the leaf is a right child (its LEFT sibling is an earlier, populated batch — not checked), and
    /// level 1 it is a left child (its RIGHT sibling must be the empty-subtree cascade `zeros[1]`). This
    /// is a genuine "last batch that is not the leftmost leaf" — the case the empty-path builder can't
    /// express.
    function _rightChildLastLeafPath() internal pure returns (uint256 mask, bytes32[] memory siblings) {
        bytes32[] memory cascade = _emptySubtreeCascade(2); // [zeros[0], zeros[1]]
        siblings = new bytes32[](2);
        siblings[0] = keccak256("earlier batch leaf (populated left sibling)");
        siblings[1] = cascade[1]; // empty right subtree at level 1
        mask = 1; // 0b01: right child at level 0, left child at level 1
    }

    /// @notice The timeout END-branch through the real verifier for a right-child last leaf: an in-time
    /// batch (`t <= deadline`) that is the chain's LAST inside the aggregated root even though it is NOT
    /// the leftmost leaf. The real verifier parses the non-zero batch-leaf mask and populated left
    /// sibling exactly as `_verifyLastBatchInRoot` expects, so the empty-path builder's blind spot
    /// (mask == 0 only) is closed against real parsing.
    function test_verifyTimeoutAbsence_realVerifier_endBranch_rightChildLastLeaf() public {
        (uint256 mask, bytes32[] memory batchSiblings) = _rightChildLastLeafPath();
        (bytes32[] memory settlementProof, bytes32 aggRoot) = _buildRealSettlementProofMasked(
            tree.root(),
            ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            DEADLINE - 1, // in-time batch -> end branch
            mask,
            batchSiblings
        );
        _importRoot(aggRoot);

        uint256 lowIndex = _lowNullifierIndex(absentValue);
        ImtProof memory absence = ImtProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_N,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: false, // end branch
            settlementProof: settlementProof,
            leaf: tree.leafAt(lowIndex),
            imtLeafIndex: lowIndex,
            imtProof: tree.merklePath(lowIndex)
        });

        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }

    /// @notice ...and the negative through the real verifier: a POPULATED right sibling on a left-child
    /// level means a later batch exists, so the batch is NOT the chain's last. The proof still
    /// authenticates (we import the matching aggregation root), and `_verifyLastBatchInRoot` — reading
    /// the same real-parsed path — rejects it with `ProofNotLastBatchInRoot` at the offending level.
    function test_verifyTimeoutAbsence_realVerifier_endBranch_RevertWhen_notLastBatch() public {
        bytes32 populatedRightSibling = keccak256("a later batch subtree (populated right sibling)");
        bytes32[] memory batchSiblings = new bytes32[](2);
        batchSiblings[0] = keccak256("earlier batch leaf (populated left sibling)");
        batchSiblings[1] = populatedRightSibling; // level 1 is a left child -> this must be empty, but isn't
        uint256 mask = 1; // 0b01

        (bytes32[] memory settlementProof, bytes32 aggRoot) = _buildRealSettlementProofMasked(
            tree.root(),
            ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            DEADLINE - 1,
            mask,
            batchSiblings
        );
        _importRoot(aggRoot); // authentication passes; the last-batch check is what must reject

        uint256 lowIndex = _lowNullifierIndex(absentValue);
        ImtProof memory absence = ImtProof({
            sourceChainId: SOURCE_CHAIN_ID,
            batchNumber: BATCH_N,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: false,
            settlementProof: settlementProof,
            leaf: tree.leafAt(lowIndex),
            imtLeafIndex: lowIndex,
            imtProof: tree.merklePath(lowIndex)
        });

        vm.expectRevert(abi.encodeWithSelector(ProofNotLastBatchInRoot.selector, 1, populatedRightSibling));
        proofLib.verifyTimeoutAbsence(absence, absentValue, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
    }
}
