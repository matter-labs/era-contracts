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
    ProofMissingSettlementLayerAnchor,
    ProofDeadlineExceeded,
    ProofInteropRootNotAfterDeadline,
    ProofNotLastBatchInRoot,
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
/// `sourceChainId` via that chain's chain-id leaf inside that SL root — which the verifier only holds
/// once the source batch has settled, so the root cannot be forged. No L2->L1 message is involved.
///
/// The flow `deadline` is a settlement-layer timestamp. Two authenticated clocks are compared to it:
///
///   - the batch's **inclusion time** `t` (`l1Timestamp`) — the settlement-layer block timestamp at
///     which the batch root was aggregated into the shared root. It is folded into the chain batch
///     leaf ({MessageHashing.batchLeafHash}), so it is proven by the same inclusion proof the leaf
///     verifier checks; we re-parse `settlementProof` with {MessageHashing._getProofData} (over the
///     same leaf and mask) and read `pd.l1BatchTimestamp`. The same parse gives
///     `pd.settlementLayerChainId` and `pd.settlementLayerBatchNumber` (the SL snapshot block the
///     root resolved `interopRoots` against).
///   - the aggregated root's **creation time** `T` — the SL block timestamp at which the imported
///     aggregation root `interopRoots[slChainId][slBlock]` was created. It is imported alongside the
///     root as `interopRootTimestamps[slChainId][slBlock]` and is double checked against
///     `MessageRoot.historicalRootTimestamp` when the importing batch settles, so it is as
///     trustworthy as the root itself.
///
/// A flow's `deadline`, `t` and `T` are only comparable if all legs settle on the same settlement
/// layer, so {verifyInclusion} / {verifyTimeoutAbsence} require the resolved `slChainId` to equal the
/// flow's `settlementLayerChainId` (else {ProofSettlementLayerMismatch}).
///
/// A leg FINALIZES iff its commit value is present in the batch-END IMT root (leaf 3) of a batch with
/// `t < deadline`.
///
/// A leg TIMES OUT (is refundable) via an aggregated root created after the deadline (`T >= deadline`)
/// plus one batch of the source chain inside that root:
///   - if the batch's `t >= deadline`: the commit value is absent from the batch-BEGIN IMT root
///     (leaf 2). The tree is append-only and `begin(N) == end(N-1)`, so absence at the begin of a
///     late batch means absence from every batch with `t < deadline` — the leg can never finalize.
///   - if the batch's `t < deadline`: the batch is additionally proven to be the chain's LAST batch
///     inside the aggregated root (every "left child" hop of the batch-leaf path carries the empty
///     right-subtree hash), and the commit value is absent from the batch-END IMT root (leaf 3).
///     Since the root was created at `T >= deadline`, any batch aggregated after it has
///     `t' >= T >= deadline`, so the proven batch's end root is the final IMT state reachable before
///     the deadline — absence there means the leg can never finalize. This branch restores refund
///     liveness for a source chain that HALTS and never settles a post-deadline batch; every
///     registered chain has at least one batch in the shared root (a genesis leaf is seeded at
///     registration — see {MessageRootBase._addNewChain}), so the required "last batch" always exists.
///
/// Both timeout branches are mutually exclusive with finalization: a value committed in a batch `B`
/// with `t_B < deadline` is contained in `begin(L)` of every batch `L` with `t_L >= deadline` (batch
/// order follows aggregation-time order) and in `end(L')` of the last batch `L'` of any root with
/// `T >= deadline > t_B` (that root already contains `B`, so `L' >= B`).
///
/// Membership (inclusion) and non-membership (low-nullifier) against the authenticated root are
/// delegated to {IndexedMerkleTree}, the single shared IMT engine.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` is present in `_proof.sourceChainId`'s batch-END IMT root as of
    /// a batch settled on `_expectedSlChainId` with `l1Timestamp < _deadline`.
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
        // The value's batch must have settled strictly before the deadline (`t < deadline`; a batch
        // with `t >= deadline` is late). `t` only rises, so a commit can't be back-dated to look
        // in-time after the fact.
        if (batchTimestamp >= _deadline) {
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

    /// @notice Timeout proof: shows `_commitValue` was not committed before the deadline and the flow
    /// can never finalize.
    /// @dev The proof anchors on an aggregated root created after the deadline (`T >= _deadline`,
    /// where `T` is the imported `interopRootTimestamps[slChainId][slBlock]`) plus one batch of the
    /// source chain inside it, and branches on the batch's inclusion time `t`:
    ///   - `t >= _deadline`: low-nullifier non-inclusion against the batch-BEGIN IMT root (leaf 2).
    ///     Append-only + `begin(N) == end(N-1)` make this equivalent to absence from every in-time
    ///     batch.
    ///   - `t < _deadline`: the batch must be the chain's LAST batch inside the aggregated root
    ///     (all right siblings on the batch-leaf path are empty subtrees), and the non-inclusion is
    ///     checked against the batch-END IMT root (leaf 3). Any batch aggregated after this root has
    ///     `t' >= T >= _deadline`, so this end root is the final IMT state reachable in time; this
    ///     branch keeps a halted source chain (one that never settles a post-deadline batch)
    ///     refundable. Every registered chain has at least one batch in the shared root (the seeded
    ///     genesis leaf), so the "last batch" always exists.
    /// A value that WAS committed in time is present in every late batch's begin root and in the end
    /// root of the last batch of every post-deadline aggregated root, so neither branch can succeed
    /// for an on-time leg — including one already finalized elsewhere. The caller
    /// ({AtomicFlowManager.authorizeRefund}) checks `_proof.sourceChainId == legSourceChainIds[i]`;
    /// the SL match is checked here.
    /// @param _absence Non-inclusion proof against the begin (late batch) or end (last in-time batch)
    /// IMT root, as described above.
    /// @param _expectedSlChainId The flow's `settlementLayerChainId` the proof's root must settle on.
    function verifyTimeoutAbsence(
        ImtProof calldata _absence,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) internal view {
        // Peek the claimed batch inclusion time to select the branch (begin vs end leaf). The claimed
        // value is only trusted after `_authenticateRoot` below verifies the same proof word: a wrong
        // timestamp breaks the reconstructed batch leaf and the proof fails.
        uint256 imtRootLeafIndex = _peekBatchTimestamp(_absence) >= _deadline
            ? ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX
            : ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX;

        (uint256 slBlock, uint256 slChainId, uint256 batchTimestamp) = _authenticateRoot(_absence, imtRootLeafIndex);
        if (slChainId != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainId);
        }

        // The aggregated root the proof resolves against must be from after the deadline. Roots
        // imported without a timestamp (legacy path) read as 0 and are rejected. Without this bound,
        // an in-time snapshot could pass the "last batch" branch below even though later in-time
        // batches (which may contain the commit) exist.
        uint256 rootTimestamp = L2_INTEROP_ROOT_STORAGE.interopRootTimestamps(slChainId, slBlock);
        if (rootTimestamp < _deadline) {
            revert ProofInteropRootNotAfterDeadline(rootTimestamp, _deadline);
        }

        if (batchTimestamp < _deadline) {
            // In-time batch: only its END root proves anything about the deadline moment, and only if
            // no later batch made it into the (post-deadline) aggregated root.
            _verifyLastBatchInRoot(_absence.settlementProof);
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

    /// @dev Reads the batch's claimed `l1Timestamp` from the settlement proof without verifying it —
    /// the word right after the leaf-to-chain-batch-root section, exactly where
    /// {MessageHashing._getProofData} reads it. Callers must still run {_authenticateRoot} over the
    /// same proof, which folds this word into the reconstructed batch leaf and thereby authenticates it.
    function _peekBatchTimestamp(ImtProof calldata _imtProof) private pure returns (uint256) {
        bytes32[] calldata proof = _imtProof.settlementProof;
        MessageHashing.ProofMetadata memory metadata = MessageHashing.parseProofMetadata(proof);
        if (metadata.finalProofNode) {
            // A final-node proof carries no aggregation hop and hence no batch timestamp word.
            revert ProofMissingSettlementLayerAnchor(_imtProof.sourceChainId, _imtProof.batchNumber);
        }
        return uint256(proof[metadata.proofStartIndex + metadata.logLeafProofLen]);
    }

    /// @dev Verifies that the proven batch leaf is the LAST leaf of the source chain's batch tree
    /// inside the aggregated root: on every level of the batch-leaf Merkle path where the current
    /// node is a left child (mask bit 0), the right sibling must be the empty-subtree hash for that
    /// level (`zeros[0] = CHAIN_TREE_EMPTY_ENTRY_HASH`, `zeros[i+1] = keccak(zeros[i] || zeros[i])` —
    /// the `DynamicIncrementalMerkle` zero cascade the settlement layer's chain tree is built with).
    /// A non-last leaf necessarily has a populated right subtree on some level, whose hash cannot
    /// collide with the zero cascade. The path itself (siblings + mask) is authenticated by the
    /// {_authenticateRoot} run over the same proof bytes: its length and contents are pinned by the
    /// chain-id leaf committed inside the aggregated root.
    function _verifyLastBatchInRoot(bytes32[] calldata _proof) private pure {
        MessageHashing.ProofMetadata memory metadata = MessageHashing.parseProofMetadata(_proof);
        // Proof word layout after the metadata word (see {MessageHashing._getProofData}):
        // [logLeafProofLen top-tree siblings][l1Timestamp][batchLeafProofMask][batchLeafProofLen siblings]...
        uint256 ptr = metadata.proofStartIndex + metadata.logLeafProofLen + 1;
        uint256 mask = uint256(_proof[ptr]);
        ++ptr;
        bytes32 zeroSubtreeHash = CHAIN_TREE_EMPTY_ENTRY_HASH;
        uint256 levels = metadata.batchLeafProofLen;
        for (uint256 i = 0; i < levels; ++i) {
            if ((mask >> i) & 1 == 0) {
                bytes32 sibling = _proof[ptr + i];
                if (sibling != zeroSubtreeHash) {
                    revert ProofNotLastBatchInRoot(i, sibling);
                }
            }
            zeroSubtreeHash = Merkle.efficientHash(zeroSubtreeHash, zeroSubtreeHash);
        }
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
