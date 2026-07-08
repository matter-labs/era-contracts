// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTree} from "../../common/libraries/IndexedMerkleTree.sol";
import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "../IAtomicInterop.sol";
import {ProofData} from "../../common/Messaging.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";
import {ChainBatchRootTree} from "../../common/libraries/ChainBatchRootTree.sol";
import {L2_MESSAGE_VERIFICATION} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {
    ProofImtRootInclusionFailed,
    ProofInvalidChainBatchRootDepth,
    ProofMissingSettlementLayerAnchor,
    ProofDeadlineExceeded,
    ProofDeadlineNotExceeded,
    ProofInclusionFailed,
    ProofNonInclusionFailed,
    ProofSettlementLayerMismatch
} from "../AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Cross-chain authentication for the L1-free atomic interop flow.
///
/// A flow leg's commit value lives in its origin chain's {L2InteropCommitmentTree} (an Indexed
/// Merkle Tree). The bootloader snapshots that tree's root at every batch boundary and commits both
/// snapshots into the batch's **chain batch root** — a fixed height-3 tree whose leaf 2 is the IMT
/// root at batch begin and leaf 3 the IMT root at batch end (see {ChainBatchRootTree}). The verifying
/// chain authenticates a claimed IMT root as that leaf: the accepted (multi-hop) proof terminates at
/// an imported SL aggregation root `interopRoots[slChainId][slBlock]` and binds the batch to
/// `sourceChainId` via that chain's chain-id leaf inside the SL root — which the verifier only holds
/// once the source batch has settled, so the root cannot be forged. No L2->L1 message is involved.
///
/// The flow `deadline` is a settlement-layer timestamp. It is not carried in the proof struct
/// (that would be spoofable); instead each batch's `l1Timestamp` — the settlement-layer block
/// timestamp at which the batch root was aggregated (`t` in the inequalities below) — is derived
/// from the same proof the leaf verifier checks. We re-parse `settlementProof` with
/// {MessageHashing._getProofData} (over the same leaf and mask the verifier used) and read
/// `pd.l1BatchTimestamp`. It is authenticated because it is folded into the chain batch leaf
/// ({MessageHashing.batchLeafHash}), so it cannot be forged without breaking the chainId /
/// shared-tree path. The same parse also gives `pd.settlementLayerChainId` and
/// `pd.settlementLayerBatchNumber` (the SL snapshot block the root resolved `interopRoots` against).
///
/// A flow's `deadline` and `t` are only comparable if all legs settle on the same settlement layer,
/// so {verifyInclusion} / {verifyTimeoutAbsence} require the resolved `slChainId` to equal the
/// flow's `settlementLayerChainId` (else {ProofSettlementLayerMismatch}).
///
/// A leg finalizes iff its commit value is present in the batch-END IMT root (leaf 3) of a batch
/// with `t <= deadline`. A leg times out iff its commit value is absent from the batch-BEGIN IMT
/// root (leaf 2) of a batch with `t > deadline`: the tree is append-only and `begin(N) == end(N-1)`,
/// so absence at the begin of a late batch means the value is absent from every in-time batch — in
/// particular from the last one — and the flow can never finalize. Conversely a value committed in
/// time is present in every late batch's begin root, so both proofs can never hold at once. A late
/// commit (landing in a batch with `t > deadline`) stays refundable via the begin root of the batch
/// it landed in (or any earlier late batch), and a chain whose first-ever settled batch is already
/// late is refundable against that batch's begin root (the seeded genesis root). The single
/// remaining refund-liveness gap is a source chain that halts and never settles a batch with
/// `t > deadline` at all.
/// TODO: add a halt branch that restores refund liveness for a halted source with no post-deadline
/// batch; it needs a "highest-leaf" SL chain-tree proof not yet exposed by the shared verifier.
///
/// Membership (inclusion) and non-membership (low-nullifier) against the authenticated root are
/// delegated to {IndexedMerkleTree}, the single shared IMT engine.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` is present in `_proof.sourceChainId`'s batch-END IMT root as of
    /// a batch settled on `_expectedSlChainId` with `l1Timestamp <= _deadline`.
    /// @dev The proof is bound to the correct chain by `_commitValue` itself: it bakes in the
    /// chain-specific `bundleHash`, so a leg's commit value can only be inserted into its own source
    /// chain's tree, and the membership check below can only pass against that chain. The authenticated
    /// root's settlement layer must equal `_expectedSlChainId` so per-leg `t`/`deadline` comparisons
    /// share one SL clock.
    /// @param _expectedSlChainId The flow's `settlementLayerChainId` the proof's root must settle on.
    function verifyInclusion(
        ImtProof calldata _proof,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) internal view {
        (, uint256 slChainId, uint256 batchTimestamp) = _authenticateRoot(
            _proof,
            ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX
        );
        if (slChainId != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainId);
        }
        // The value's batch must have settled no later than the deadline. `t` only rises, so a commit
        // can't be back-dated to look in-time after the fact.
        if (batchTimestamp > _deadline) {
            revert ProofDeadlineExceeded(batchTimestamp, _deadline);
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
    /// never finalize, by proving it absent (low-nullifier non-inclusion) from the batch-BEGIN IMT root
    /// of a batch with `l1Timestamp > _deadline` on the source chain.
    /// @dev Soundness: the IMT is append-only and the begin root of batch `N` equals the end root of
    /// batch `N-1`, so a value absent from a late batch's begin root is absent from every batch with
    /// `t <= _deadline` (monotone `t`), i.e. the flow's inclusion proofs can never pass. A value that
    /// WAS committed in time is present in every late begin root, so this cannot succeed for an on-time
    /// leg — including one already finalized elsewhere. Requiring the batch itself to be late is what
    /// blocks a force-refund off a stale/genesis root (an in-time snapshot proves nothing about the
    /// deadline moment). The caller ({AtomicFlowManager.authorizeRefund}) checks
    /// `_proof.sourceChainId == legSourceChainIds[i]`; the SL match is checked here.
    /// @param _absence Non-inclusion proof against the begin root of a late batch.
    /// @param _expectedSlChainId The flow's `settlementLayerChainId` the proof's root must settle on.
    function verifyTimeoutAbsence(
        ImtProof calldata _absence,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) internal view {
        (, uint256 slChainId, uint256 batchTimestamp) = _authenticateRoot(
            _absence,
            ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX
        );
        if (slChainId != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainId);
        }
        if (batchTimestamp <= _deadline) {
            // The batch is not past the deadline, so its begin root says nothing about the deadline
            // moment (the value could still land in this or a later in-time batch); reject.
            revert ProofDeadlineNotExceeded(batchTimestamp, _deadline);
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

    /// @dev Authenticates `_proof.chainImtRoot` as the chain-batch-root leaf `_imtRootLeafIndex`
    /// (2 = batch begin, 3 = batch end; see {ChainBatchRootTree}) of `(_proof.sourceChainId,
    /// _proof.batchNumber)` against the imported SL aggregation root — the accepted (multi-hop) proof
    /// terminates at `interopRoots[slChainId][slBlock]`, with the source chain bound via its chain-id
    /// leaf inside that root — and derives the settlement-layer metadata (SL snapshot block, SL chain
    /// id, and the batch's `l1Timestamp`) from that same proof.
    ///
    /// Step 1: pin the top-tree depth. The chain batch root is a fixed height-{ChainBatchRootTree.TREE_DEPTH}
    /// tree, so the leaf-to-batch-root section of the proof must be exactly that long. Without this, a
    /// longer path could descend INTO the IMT (whose internal nodes hash the same way) and pass off an
    /// IMT-internal node as "the root" — against which a crafted low-nullifier could fake non-inclusion
    /// of a genuinely committed value.
    ///
    /// Step 2: verify leaf inclusion via `proveL2LeafInclusionShared`, with the mask fixed to the
    /// begin/end leaf index chosen by the caller.
    ///
    /// Step 3: re-parse the same proof with {MessageHashing._getProofData} (same leaf, same mask) to
    /// read the SL metadata. A single-level / commit-based proof (`finalProofNode == true`) carries no
    /// SL anchor, so we reject it; a multi-hop proof exposes `pd.settlementLayerBatchNumber`,
    /// `pd.settlementLayerChainId`, and `pd.l1BatchTimestamp`.
    ///
    /// @return slBlock The SL snapshot block `interopRoots(slChainId, slBlock)` was resolved at.
    /// @return slChainId The settlement-layer chain id (callers require it to equal the flow's SL).
    /// @return batchTimestamp The batch's `l1Timestamp`, compared to the deadline.
    function _authenticateRoot(
        ImtProof calldata _proof,
        uint256 _imtRootLeafIndex
    ) private view returns (uint256 slBlock, uint256 slChainId, uint256 batchTimestamp) {
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

        // Re-parse the same proof for the SL metadata. The leaf and mask are exactly what the verifier
        // consumed, so the parse is bound to the verified root.
        ProofData memory pd = MessageHashing._getProofData({
            _chainId: _proof.sourceChainId,
            _batchNumber: _proof.batchNumber,
            _leafProofMask: _imtRootLeafIndex,
            _leaf: _proof.chainImtRoot,
            _proof: _proof.settlementProof
        });
        // A final-node (single-level / commit-based) proof has no settlement-layer anchor, so neither the
        // deadline nor `t` can be checked against it.
        if (pd.finalProofNode) revert ProofMissingSettlementLayerAnchor(_proof.sourceChainId, _proof.batchNumber);

        slBlock = pd.settlementLayerBatchNumber;
        slChainId = pd.settlementLayerChainId;
        batchTimestamp = pd.l1BatchTimestamp;
    }
}
