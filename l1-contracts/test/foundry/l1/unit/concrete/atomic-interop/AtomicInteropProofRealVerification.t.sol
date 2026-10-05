// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";
import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";

import {ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {ProofNotLastBatchInRoot} from "contracts/atomic-interop/AtomicInteropErrors.sol";

/// @notice Exercises a multi-level, non-leftmost batch-leaf proof through the real
/// `L2MessageVerification` and imported `L2InteropRootStorage` root. The shared live-tree builder
/// produces only the one-level first-post-genesis path (mask `0b1`), so this suite forward-computes a
/// two-level right-child last-leaf path and its invalid counterpart with the builder's {_settlementProof}.
contract AtomicInteropProofRealVerificationTest is AtomicInteropProofBuilder {
    /// @dev Per-suite proof fixture values. Not hoisted onto the builder: other derived suites pick
    /// their own (the execute abstract uses a different `SL_BLOCK`).
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant BATCH_N = 100;
    uint256 internal constant SL_BLOCK = 555;

    uint256 internal absentValue;

    function setUp() public {
        _setUpAtomicFixtures(); // deploys the real verifier; no test here ever calls _mockVerifier
        absentValue = AtomicFlowFixtures.commitValue(keccak256("flowB"), keccak256("bundleB"));
    }

    /// @dev The creation time imported for the aggregation root. Post-deadline so the timeout tests'
    /// `T > deadline` guard holds; the inclusion test does not read it.
    uint256 internal constant INTEROP_ROOT_TIMESTAMP = uint256(DEADLINE) + 5;

    /// @dev Imports `_root` into the real L2InteropRootStorage at (SL, SL_BLOCK) with a post-deadline
    /// creation timestamp ({INTEROP_ROOT_TIMESTAMP}).
    function _importRoot(bytes32 _root) internal {
        _importInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, SL_BLOCK, INTEROP_ROOT_TIMESTAMP, _root);
    }

    /// @dev A batch-leaf path for a RIGHT-child last leaf at mask `0b01` in a 2-level chain tree: level
    /// 0 the leaf is a right child (its LEFT sibling is an earlier, populated batch — not checked), and
    /// level 1 it is a left child (its RIGHT sibling must be the empty-subtree cascade `zeros[1]`). This
    /// is a genuine "last batch that is not the leftmost leaf" with an empty right subtree above it —
    /// the case the one-level live-tree builder cannot express.
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
    /// sibling exactly as `_verifyLastBatchInRoot` expects, closing the one-level builder's blind spot
    /// around left-child levels and their required empty-subtree cascade.
    function test_verifyTimeoutAbsence_realVerifier_endBranch_rightChildLastLeaf() public {
        (uint256 mask, bytes32[] memory batchSiblings) = _rightChildLastLeafPath();
        (bytes32[] memory settlementProof, bytes32 aggRoot) = _settlementProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _imtRoot: tree.root(),
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1, // in-time batch -> end branch
            _batchLeafProofMask: mask,
            _batchLeafSiblings: batchSiblings
        });
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

        // This suite exists to run the REAL verifier, so pin the call: `verifyTimeoutAbsence` returns
        // nothing, so without this a no-op `_authenticateRoot` would pass.
        _expectRootAuthentication(absence, ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX);
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

        (bytes32[] memory settlementProof, bytes32 aggRoot) = _settlementProof({
            _sourceChainId: SOURCE_CHAIN_ID,
            _batchNumber: BATCH_N,
            _imtRoot: tree.root(),
            _slChainId: SETTLEMENT_LAYER_CHAIN_ID,
            _slBlock: SL_BLOCK,
            _l1Timestamp: DEADLINE - 1,
            _batchLeafProofMask: mask,
            _batchLeafSiblings: batchSiblings
        });
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
