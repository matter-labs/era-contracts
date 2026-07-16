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
    IMTProofInvalidChainBatchRootDepth,
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
/// @notice Cross-chain authentication for the atomic interop flow.
///
/// A flow leg's commit value lives in its origin chain's {L2InteropCommitmentTree} (an Indexed
/// Merkle Tree). The bootloader snapshots that tree's root at every batch boundary and commits both
/// snapshots into the batch's **chain batch root** — a fixed height-3 tree whose leaf 2 is the IMT
/// root at batch begin and leaf 3 the IMT root at batch end (see {ChainBatchRootTree}). The verifying
/// chain authenticates a claimed IMT root as that leaf: the accepted (multi-hop) proof terminates at
/// an imported SL aggregation root `interopRoots[slChainId][slBlock]` and binds the batch to
/// `sourceChainId` via that chain's chain-id leaf inside that SL root — which the verifier only holds
/// once the source batch has settled, so the root cannot be forged.
///
/// The flow `deadline` is a settlement-layer timestamp. Two authenticated clocks are compared to it:
///
///   - the batch's **inclusion time** `t` (`l1BatchTimestamp`) — the settlement-layer block timestamp at
///     which the batch root was aggregated into the shared root. It is folded into the chain batch
///     leaf ({MessageHashing.batchLeafHash}), so it is proven by the same inclusion proof the leaf
///     verifier checks; we re-parse `settlementProof` with {MessageHashing._getProofData} (over the
///     same leaf and mask) and read `pd.l1BatchTimestamp`. The same parse gives
///     `pd.settlementLayerChainId` and `pd.settlementLayerBatchNumber` (the SL snapshot block the
///     root resolved `interopRoots` against).
///   - the aggregated root's **creation time** `T` — the SL block timestamp at which the imported
///     aggregation root `interopRoots[slChainId][slBlock]` was created. It is imported alongside the
///     root (one `(blockNumber, root, timestamp)` tuple; see {IL2InteropRootStorage}) and is double
///     checked against `MessageRoot.historicalRoot` when the importing batch settles, so it is as
///     trustworthy as the root itself.
///
/// INVARIANT: atomic interop is L1-only in this release — every chain participating in a flow
/// settles on L1, enforced by {AtomicFlowManager}, which rejects any flow whose
/// `settlementLayerChainId` is not the L1 chain id. `deadline`, `t` and `T` are therefore all
/// timestamps of an L1 block. Mechanically, {verifyInclusion} / {verifyTimeoutAbsence} still
/// require each proof's resolved `slChainId` to equal the flow's `settlementLayerChainId` (else
/// {ProofSettlementLayerMismatch}), which under the invariant pins every leg's proof to L1.
///
/// A leg FINALIZES iff its commit value is present in the batch-END IMT root (leaf 3) of a batch with
/// `t <= deadline`.
///
/// A leg TIMES OUT (is refundable) via an aggregated root created strictly after the deadline
/// (`T > deadline`) plus one batch of the source chain inside that root. The prover declares the
/// branch explicitly (`ImtProof.provesAgainstBeginRoot`), and the declaration is validated against
/// the authenticated batch inclusion time `t` after the proof is verified:
///   - begin branch (`t > deadline` required): the commit value is absent from the batch-BEGIN IMT
///     root (leaf 2). The tree is append-only and `begin(N) == end(N-1)`, so absence at the begin of
///     a late batch means absence from every batch with `t <= deadline` — the leg can never finalize.
///   - end branch (`t <= deadline` required): the batch is additionally proven to be the chain's
///     LAST batch inside the aggregated root (every "left child" hop of the batch-leaf path carries
///     the empty right-subtree hash), and the commit value is absent from the batch-END IMT root
///     (leaf 3).
///     Since the root was created at `T > deadline`, any batch aggregated after it has
///     `t' >= T > deadline`, so the proven batch's end root is the final IMT state reachable in time
///     — absence there means the leg can never finalize. This branch restores refund liveness for a
///     source chain that HALTS and never settles a post-deadline batch; every chain interop can
///     target has at least one batch in the shared root (freshly created chains get a genesis
///     batch leaf at creation — see {MessageRootBase.seedGenesisRoot} — and `ChainRegistrationSender` refuses
///     to enable interop towards a chain with an empty tree), so the required "last batch" always
///     exists.
///
/// SOUNDNESS — both timeout branches are mutually exclusive with finalization: a value committed in a
/// batch `B` with `t_B <= deadline` is contained in `begin(L)` of every batch `L` with
/// `t_L > deadline` (batch order follows aggregation-time order) and in `end(L')` of the last batch
/// `L'` of any root with `T > deadline >= t_B` (that root already contains `B`, so `L' >= B`).
///
/// COMPLETENESS — if a leg has really timed out (its commit value is absent from every batch with
/// `t <= deadline`), a valid timeout proof can always be produced from ANY aggregated root with
/// `T > deadline`, even if the source chain inserts the commit value later on: if the root contains a
/// batch with `t > deadline`, the FIRST such batch works (its begin root equals the end root of the
/// last in-time batch, which cannot contain the value); otherwise the chain's last batch in the root
/// is in time and its end root — the final in-time IMT state — cannot contain the value either.
///
/// Membership (inclusion) and non-membership (low-nullifier) against the authenticated root are
/// delegated to {IndexedMerkleTree}, the single shared IMT engine.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` is present in `_proof.sourceChainId`'s batch-END IMT root as of
    /// a batch settled on `_expectedSlChainId` with `l1BatchTimestamp <= _deadline` (the finality condition
    /// from the library header).
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
        (, uint256 slChainId, uint256 l1BatchTimestamp) = _authenticateRoot(
            _proof,
            ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX
        );
        if (slChainId != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainId);
        }
        // The value's batch must have settled no later than the deadline. `t` only rises, so a commit
        // can't be back-dated to look in-time after the fact.
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
    /// never finalize. Implements the timeout branch of the protocol described in the library header:
    /// resolved against a settlement-layer interop root created strictly after the deadline (`T > _deadline`), the
    /// commit value is proven absent from the batch-BEGIN IMT root of a late batch
    /// (`l1BatchTimestamp > _deadline`) or from the batch-END IMT root of the chain's LAST batch inside
    /// the settlement-layer interop root (`l1BatchTimestamp <= _deadline`).
    /// @dev The caller ({AtomicFlowManager.authorizeRefund}) checks
    /// `_proof.sourceChainId == legSourceChainIds[i]`; the SL match is checked here.
    /// @param _absence Non-inclusion proof against the begin (late batch) or end (last in-time batch)
    /// IMT root, as described above.
    /// @param _expectedSlChainId The flow's `settlementLayerChainId` the proof's root must settle on.
    function verifyTimeoutAbsence(
        ImtProof calldata _absence,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) internal view {
        // The branch (begin vs end leaf) is an explicit prover input, mapped to the leaf mask here
        // and validated against the authenticated batch inclusion time below — no unverified value
        // drives control flow. The bool constrains the selection to the two IMT leaves, so
        // authentication can never be pointed at the logs/multichain leaves.
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
        // The settlement-layer interop root the proof resolves against must exist and be created
        // strictly after the deadline.
        if (rootTimestamp <= _deadline) {
            revert ProofInteropRootNotAfterDeadline(rootTimestamp, _deadline);
        }

        // Validate the declared branch against the authenticated inclusion time (see the library
        // header): the begin root only proves anything for a late batch, the end root only for an
        // in-time batch that is additionally the chain's LAST batch inside the (post-deadline)
        // settlement-layer interop root.
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

    /// @dev Verifies that the proven batch leaf is the LAST leaf of the source chain's batch tree
    /// inside the aggregated root: on every level of the batch-leaf Merkle path where the current
    /// node is a left child (mask bit 0), the right sibling must be the empty-subtree hash for that
    /// level (`zeros[0] = CHAIN_TREE_EMPTY_ENTRY_HASH`, `zeros[i+1] = keccak(zeros[i] || zeros[i])` —
    /// the `DynamicIncrementalMerkle` zero cascade the settlement layer's chain tree is built with).
    /// A non-last leaf necessarily has a populated right subtree on some level, whose hash cannot
    /// collide with the zero cascade. The path itself (siblings + mask) is authenticated by the
    /// {_authenticateRoot} run over the same proof bytes: its length and contents are pinned by the
    /// chain-id leaf committed inside the aggregated root.
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
    /// _proof.batchNumber)` against the imported SL aggregation root — the accepted (multi-hop) proof
    /// terminates at `interopRoots[slChainId][slBlock]`, with the source chain bound via its chain-id
    /// leaf inside that root — and derives the settlement-layer metadata (SL snapshot block, SL chain
    /// id, and the batch's `l1BatchTimestamp`) from that same proof.
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
    /// settlement-layer block reference, so we reject it; a multi-hop proof exposes `pd.settlementLayerBatchNumber`,
    /// `pd.settlementLayerChainId`, and `pd.l1BatchTimestamp`.
    ///
    /// @return slBlock The SL snapshot block `interopRoots(slChainId, slBlock)` was resolved at.
    /// @return slChainId The settlement-layer chain id (callers require it to equal the flow's SL).
    /// @return l1BatchTimestamp The batch's settlement-layer inclusion timestamp, compared to the deadline.
    function _authenticateRoot(
        ImtProof calldata _proof,
        uint256 _imtRootLeafIndex
    ) private view returns (uint256 slBlock, uint256 slChainId, uint256 l1BatchTimestamp) {
        MessageHashing.ProofMetadata memory metadata = MessageHashing.parseProofMetadata(_proof.settlementProof);
        if (metadata.logLeafProofLen != ChainBatchRootTree.TREE_DEPTH) {
            revert IMTProofInvalidChainBatchRootDepth(ChainBatchRootTree.TREE_DEPTH, metadata.logLeafProofLen);
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
        // A final-node (single-level / commit-based) proof has no settlement-layer batch reference, so neither the
        // deadline nor `t` can be checked against it.
        if (pd.finalProofNode) revert ProofMissingSettlementLayerBatch(_proof.sourceChainId, _proof.batchNumber);

        slBlock = pd.settlementLayerBatchNumber;
        slChainId = pd.settlementLayerChainId;
        l1BatchTimestamp = pd.l1BatchTimestamp;
    }
}
