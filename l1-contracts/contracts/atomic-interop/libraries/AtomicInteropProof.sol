// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTree} from "../../common/libraries/IndexedMerkleTree.sol";
import {Merkle} from "../../common/libraries/Merkle.sol";
import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "../IAtomicInterop.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";
import {ChainBatchRootTree} from "../../common/libraries/ChainBatchRootTree.sol";
import {L2_INTEROP_ROOT_STORAGE, L2_MESSAGE_VERIFICATION} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {CHAIN_TREE_EMPTY_ENTRY_HASH} from "../../core/message-root/IMessageRoot.sol";
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
} from "../AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Cross-chain authentication for the atomic interop flow: verifies a leg's commit value
/// present in (finality) or absent from (timeout) its source chain's IMT, with the claimed IMT root
/// authenticated as a chain-batch-root leaf against an imported interop root. The finality/timeout
/// conditions and their soundness/completeness arguments are specified canonically in
/// {protocol-docs/atomicity/proofs.md}.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` is present in `_proof.sourceChainId`'s batch-END IMT root as of
    /// a batch settled on `_expectedSlChainId` with `l1BatchTimestamp <= _deadline` (the finality
    /// condition from the library header).
    /// @dev Inclusion is self-binding: `_commitValue` bakes in the chain-specific `bundleHash`, so it
    /// can only ever pass against the leg's true source chain.
    /// @param _expectedSlChainId The flow's `settlementLayerChainId` the proof's root must settle on.
    function verifyInclusion(
        ImtProof calldata _proof,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) internal view {
        (, uint256 slChainId, uint256 l1BatchTimestamp) = _authenticateRoot(
            _proof,
            ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX
        );
        if (slChainId != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainId);
        }
        if (l1BatchTimestamp > _deadline) {
            revert ProofDeadlineExceeded(l1BatchTimestamp, _deadline);
        }
        bool included = IndexedMerkleTree.verifyInclusion({
            _root: _proof.chainImtRoot,
            _value: _commitValue,
            _leaf: _proof.leaf,
            _leafIndex: _proof.imtLeafIndex,
            _proof: _proof.imtProof
        });
        if (!included) revert ProofInclusionFailed(_proof.chainImtRoot, _commitValue);
    }

    /// @notice Timeout proof: shows `_commitValue` was not committed by the deadline and the flow can
    /// never finalize (the timeout condition from the library header, either branch).
    /// @dev The caller ({AtomicFlowManager.authorizeRefund}) checks
    /// `_proof.sourceChainId == legSourceChainIds[i]`; the SL match is checked here.
    /// @param _absence Non-inclusion proof against the begin (late batch) or end (last in-time batch)
    /// IMT root.
    /// @param _expectedSlChainId The flow's `settlementLayerChainId` the proof's root must settle on.
    function verifyTimeoutAbsence(
        ImtProof calldata _absence,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) internal view {
        // The declared branch is validated against the authenticated batch inclusion time below —
        // no unverified value drives control flow.
        uint256 imtRootLeafIndex = _absence.provesAgainstBeginRoot
            ? ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX
            : ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX;

        (uint256 slBlock, uint256 slChainId, uint256 l1BatchTimestamp) = _authenticateRoot(_absence, imtRootLeafIndex);
        if (slChainId != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainId);
        }

        uint256 rootTimestamp = L2_INTEROP_ROOT_STORAGE.interopRoots(slChainId, slBlock).timestamp;
        if (rootTimestamp == 0) {
            revert ProofSettlementLayerInteropRootNotImported(slChainId, slBlock);
        }
        if (rootTimestamp <= _deadline) {
            revert ProofInteropRootNotAfterDeadline(rootTimestamp, _deadline);
        }

        // Branch conditions per the library header.
        if (_absence.provesAgainstBeginRoot) {
            if (l1BatchTimestamp <= _deadline) {
                revert ProofTimeoutBranchMismatch(true, l1BatchTimestamp, _deadline);
            }
        } else {
            if (l1BatchTimestamp > _deadline) {
                revert ProofTimeoutBranchMismatch(false, l1BatchTimestamp, _deadline);
            }
            // The batch-leaf path is read only AFTER `_authenticateRoot` verified the same proof
            // words (see {MessageHashing.readAggregationHopPath}).
            _verifyLastBatchInRoot(MessageHashing.readAggregationHopPath(_absence.settlementProof));
        }

        bool absent = IndexedMerkleTree.verifyNonInclusion({
            _root: _absence.chainImtRoot,
            _value: _commitValue,
            _lowLeaf: _absence.leaf,
            _lowLeafIndex: _absence.imtLeafIndex,
            _lowLeafProof: _absence.imtProof
        });
        if (!absent) revert ProofNonInclusionFailed(_absence.chainImtRoot, _commitValue);
    }

    /// @dev Verifies the proven batch leaf is the LAST leaf of the source chain's batch tree inside
    /// the aggregated root: wherever the path node is a left child (mask bit 0), the right sibling
    /// must be that level's empty-subtree hash (the `DynamicIncrementalMerkle` zero cascade). The path
    /// itself is authenticated by the {_authenticateRoot} run over the same proof bytes.
    function _verifyLastBatchInRoot(MessageHashing.AggregationHopPath memory _path) private pure {
        uint256 mask = _path.batchLeafProofMask;
        bytes32 zeroSubtreeHash = CHAIN_TREE_EMPTY_ENTRY_HASH;
        uint256 levels = _path.batchLeafSiblings.length;
        for (uint256 i = 0; i < levels; ++i) {
            if ((mask >> i) & 1 == 0) {
                bytes32 sibling = _path.batchLeafSiblings[i];
                if (sibling != zeroSubtreeHash) {
                    revert ProofNotLastBatchInRoot(i, sibling);
                }
            }
            zeroSubtreeHash = Merkle.efficientHash(zeroSubtreeHash, zeroSubtreeHash);
        }
    }

    /// @dev Authenticates `_proof.chainImtRoot` as the chain-batch-root leaf `_imtRootLeafIndex`
    /// (2 = batch begin, 3 = batch end; see {ChainBatchRootTree}) of `(_proof.sourceChainId,
    /// _proof.batchNumber)` against the imported SL aggregation root, and derives the settlement-layer
    /// metadata from the same proof.
    /// @dev The exact-depth check is load-bearing: without it, a longer path could descend INTO the
    /// IMT (whose internal nodes hash the same way) and pass off an IMT-internal node as "the root" —
    /// against which a crafted low-nullifier could fake non-inclusion of a committed value.
    /// @return slBlock The SL snapshot block `interopRoots(slChainId, slBlock)` was resolved at.
    /// @return slChainId The settlement-layer chain id (callers require it to equal the flow's SL).
    /// @return l1BatchTimestamp The batch's settlement-layer inclusion timestamp, compared to the deadline.
    function _authenticateRoot(
        ImtProof calldata _proof,
        uint256 _imtRootLeafIndex
    ) private view returns (uint256 slBlock, uint256 slChainId, uint256 l1BatchTimestamp) {
        MessageHashing.ProofMetadata memory metadata = MessageHashing.parseProofMetadata(_proof.settlementProof);
        if (metadata.logLeafProofLen != ChainBatchRootTree.TREE_DEPTH) {
            revert ProofInvalidChainBatchRootDepth(ChainBatchRootTree.TREE_DEPTH, metadata.logLeafProofLen);
        }

        bool ok = L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared({
            _chainId: _proof.sourceChainId,
            _blockOrBatchNumber: _proof.batchNumber,
            _leafProofMask: _imtRootLeafIndex,
            _leaf: _proof.chainImtRoot,
            _proof: _proof.settlementProof
        });
        if (!ok) revert ProofImtRootInclusionFailed(_proof.sourceChainId, _proof.batchNumber, _proof.chainImtRoot);

        // A final-node (single-level) proof has no settlement-layer batch reference, so neither the
        // deadline nor `t` could be checked against it.
        if (metadata.finalProofNode) {
            revert ProofMissingSettlementLayerBatch(_proof.sourceChainId, _proof.batchNumber);
        }

        // The SL metadata words are read positionally AFTER the verifier above authenticated the
        // same proof bytes (see {MessageHashing.readSettlementLayerReference}) — this avoids
        // re-running the Merkle climbs `proveL2LeafInclusionShared` already performed.
        MessageHashing.SettlementLayerReference memory slReference = MessageHashing.readSettlementLayerReference(
            _proof.settlementProof
        );
        slBlock = slReference.settlementLayerBatchNumber;
        slChainId = slReference.settlementLayerChainId;
        l1BatchTimestamp = slReference.l1BatchTimestamp;
    }
}
