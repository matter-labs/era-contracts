// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTree} from "../../common/libraries/IndexedMerkleTree.sol";
import {Merkle} from "../../common/libraries/Merkle.sol";
import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "../IAtomicInterop.sol";
import {ProofData} from "../../common/Messaging.sol";
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
/// authenticated as a chain-batch-root leaf against an imported interop root (see {ImtProof} and
/// {protocol-docs/atomic-interop.md} for the mechanics). This header is the canonical spec of the
/// finality/timeout conditions and their soundness/completeness arguments.
///
/// Two authenticated clocks are compared to the flow `deadline` (a settlement-layer timestamp):
///   - `t` (`l1BatchTimestamp`) — when the batch root was aggregated into the shared root; folded into
///     the chain batch leaf, hence proven by the same inclusion proof and re-parsed from
///     `settlementProof`.
///   - `T` — the imported aggregation root's creation time, stored alongside the root (see
///     {IL2InteropRootStorage}) and double checked on the settlement layer, so as trustworthy as the
///     root itself.
///
/// A leg FINALIZES iff its commit value is present in the batch-END IMT root (leaf 3) of a batch with
/// `t <= deadline`.
///
/// A leg TIMES OUT (is refundable) via an aggregated root created strictly after the deadline
/// (`T > deadline`) plus one batch of the source chain inside that root. The prover declares the
/// branch (`ImtProof.provesAgainstBeginRoot`), validated against the authenticated `t`:
///   - begin branch (`t > deadline` required): the value is absent from the batch-BEGIN IMT root
///     (leaf 2). The tree is append-only and `begin(N) == end(N-1)`, so absence at the begin of a
///     late batch means absence from every batch with `t <= deadline`.
///   - end branch (`t <= deadline` required): the batch is additionally proven to be the chain's LAST
///     batch inside the aggregated root, and the value is absent from its batch-END IMT root (leaf 3)
///     — the final IMT state reachable in time (any later batch has `t' >= T > deadline`). This
///     branch restores refund liveness for a source chain that HALTS; the required "last batch"
///     always exists (see {protocol-docs/atomic-interop.md}, timeout preconditions).
///
/// SOUNDNESS — both timeout branches are mutually exclusive with finalization: a value committed in a
/// batch `B` with `t_B <= deadline` is contained in `begin(L)` of every batch `L` with
/// `t_L > deadline` (batch order follows aggregation-time order) and in `end(L')` of the last batch
/// `L'` of any root with `T > deadline >= t_B` (that root already contains `B`, so `L' >= B`).
///
/// COMPLETENESS — if a leg has really timed out, a valid timeout proof can always be produced from
/// ANY aggregated root with `T > deadline`, even if the source chain inserts the value later: if the
/// root contains a batch with `t > deadline`, the FIRST such batch works (its begin root equals the
/// end root of the last in-time batch); otherwise the chain's last batch in the root is in time and
/// its end root — the final in-time IMT state — cannot contain the value either.
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

        // Re-parse the same proof (same leaf, same mask) for the SL metadata, so the parse is bound
        // to the verified root.
        ProofData memory pd = MessageHashing._getProofData({
            _chainId: _proof.sourceChainId,
            _batchNumber: _proof.batchNumber,
            _leafProofMask: _imtRootLeafIndex,
            _leaf: _proof.chainImtRoot,
            _proof: _proof.settlementProof
        });
        // A final-node (single-level) proof has no settlement-layer batch reference, so neither the
        // deadline nor `t` could be checked against it.
        if (pd.finalProofNode) revert ProofMissingSettlementLayerBatch(_proof.sourceChainId, _proof.batchNumber);

        slBlock = pd.settlementLayerBatchNumber;
        slChainId = pd.settlementLayerChainId;
        l1BatchTimestamp = pd.l1BatchTimestamp;
    }
}
