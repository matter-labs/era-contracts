// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTree} from "../../common/libraries/IndexedMerkleTree.sol";
import {ImtProof, ATOMIC_COMMIT_LEAF_TAG} from "../IAtomicInterop.sol";
import {L2Message, ProofData} from "../../common/Messaging.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";
import {L2_MESSAGE_VERIFICATION} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {L2_INTEROP_COMMITMENT_TREE_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {
    ProofRootMessageInclusionFailed,
    ProofMissingSettlementLayerAnchor,
    ProofDeadlineExceeded,
    ProofDeadlineNotExceeded,
    ProofInclusionFailed,
    ProofNonInclusionFailed,
    ProofSettlementLayerMismatch,
    ProofSourceChainMismatch,
    ProofAdjacencyNotConsecutive
} from "../AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Cross-chain authentication for the L1-free atomic interop flow.
///
/// A flow leg's commit value lives in its origin chain's {L2InteropCommitmentTree} (an Indexed
/// Merkle Tree). On every insert that tree publishes `abi.encode(root)` to L1 via the L2->L1
/// messenger. The verifying chain authenticates that single message against the interop root it
/// imported for `(sourceChainId, batchNumber)` — which it only holds once the source batch has
/// settled, so the root cannot be forged.
///
/// The flow `deadline` is a **settlement-layer (SL) timestamp**. It is NOT carried in the proof
/// struct (that would be spoofable); instead each batch's SL-assigned settlement timestamp `t` is
/// **derived from the same multi-hop proof** the message verifier checks. We independently re-parse
/// `messageProof` with {MessageHashing._getProofData} (computing the identical leaf the verifier uses)
/// and read `pd.batchSettlementTimestamp` — `t` is authenticated because it is folded into the chain
/// batch leaf ({MessageHashing.batchLeafHash}), so a prover cannot forge it without breaking the
/// authenticated chainId / shared-tree path. The same parse also exposes `pd.settlementLayerChainId` and
/// `pd.settlementLayerBatchNumber` (the SL snapshot block the root resolved `interopRoots` against).
///
/// Single-settlement-layer enforcement (BIND-SL): a flow's `deadline`/`t` are comparable across
/// legs only if all legs settle on the same SL. {verifyInclusion} / {verifyTimeoutAdjacency} therefore
/// require the resolved `slChainId` to equal the flow's `settlementLayerChainId` (else
/// {ProofSettlementLayerMismatch}).
///
/// Adjacency timeout (RULE-ADJACENCY): a leg times out iff its commit value is absent from the
/// LAST batch `N` with `t_N <= deadline`. {verifyTimeoutAdjacency} proves absence at `N` (with
/// `t_N <= deadline`) AND that the consecutive successor batch `N+1` (same source chain, same SL) has
/// `t_{N+1} > deadline` — pinning `N` as the last in-time batch. This closes the stale/genesis-root
/// force-refund (an old/empty root cannot be used, because its successor would still be `<= deadline`)
/// while keeping a genuine no-show refundable. TODO(adjacency tip branch): the spec's halt branch — `N` is
/// the highest batch of the chain aggregated in a post-`deadline` snapshot under `settlementLayerChainId`
/// — additionally restores refund LIVENESS for a halted source with no successor batch. It needs an SL
/// chain-tree "highest-leaf" proof primitive not yet exposed by `proveL2MessageInclusionShared`; it is
/// documented as future work and is a LIVENESS (not safety) extension.
///
/// Membership (inclusion) and non-membership (low-nullifier) against the authenticated root are
/// delegated to {IndexedMerkleTree}, the single shared IMT engine.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` is present in `_proof.sourceChainId`'s IMT as of an authenticated
    /// root whose batch settled on `_expectedSlChainId` with settlement timestamp `t <= _deadline` (C4).
    /// @dev The proof is bound to the correct chain by `_commitValue` itself: it bakes in the
    /// chain-specific `bundleHash`, so a leg's commit value can only ever be inserted into its own
    /// source chain's tree — the membership check below therefore can only pass against that chain.
    /// BIND-SL: the authenticated root's settlement layer MUST equal `_expectedSlChainId`, so a
    /// flow's per-leg `t`/`deadline` comparisons all share one SL clock.
    /// @param _expectedSlChainId The flow's `settlementLayerChainId` the proof's root must settle on.
    function verifyInclusion(
        ImtProof calldata _proof,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) internal view {
        (, uint256 slChainId, uint256 batchTimestamp) = _authenticateRoot(_proof);
        if (slChainId != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainId);
        }
        // C4: the value's batch must have settled no later than the deadline (an insert can never be
        // back-dated — `t` only rises — so a commit cannot be made to look in-time after the fact).
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

    /// @notice RULE-ADJACENCY timeout: verifies `_commitValue` can no longer be committed in time
    /// and the flow cannot finalize, by proving it absent from the LAST batch with `t <= _deadline` on
    /// `_proof`'s source chain — pinned via the consecutive successor witness.
    ///   - A1 (BIND-CHAIN + BIND-SL): BIND-CHAIN (proof.sourceChainId == legSourceChainIds[i]) is
    ///     enforced by caller in authorizeRefund; BIND-SL (slChainId == settlementLayerChainId) is
    ///     enforced here (lines 122-124). Both must hold for settlement-layer comparability.
    ///   - A2: `_absence` authenticates batch `N` with `t_N <= _deadline`, and `_commitValue` is absent
    ///     (low-nullifier non-membership) from `N`'s IMT root.
    ///   - A3 (live branch): `_successor` authenticates the consecutive batch `N+1` of the SAME source
    ///     chain and SAME settlement layer with `t_{N+1} > _deadline`, so `N` is the last in-time batch.
    /// By per-chain append-only + monotone `t`, a value present in any batch with `t <= _deadline` is
    /// present in `N` too — so this cannot succeed for an on-time, finalized leg (closing the stale-root
    /// double-mint).
    /// @param _absence Non-inclusion proof at batch `N` (gives `t_N`, `N = _absence.batchNumber`).
    /// @param _successor Root-authentication proof of batch `N+1` (gives `t_{N+1}`; its IMT membership
    /// fields are unused — only its existence and timestamp matter).
    /// @param _expectedSlChainId The flow's `settlementLayerChainId` both proofs must settle on.
    function verifyTimeoutAdjacency(
        ImtProof calldata _absence,
        ImtProof calldata _successor,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) internal view {
        // ── A2: absence at batch N, with t_N <= deadline ──
        (, uint256 slChainIdN, uint256 tN) = _authenticateRoot(_absence);
        if (slChainIdN != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainIdN);
        }
        if (tN > _deadline) {
            // Batch N is itself past the deadline -> it is not an in-time batch; reject (a stale absence
            // batch must be at/before the deadline to bound the value's potential commit window).
            revert ProofDeadlineExceeded(tN, _deadline);
        }
        bool absent = IndexedMerkleTree.verifyNonInclusion({
            _root: _absence.chainImtRoot,
            _value: _commitValue,
            _lowLeaf: _absence.leaf,
            _lowLeafIndex: _absence.imtLeafIndex,
            _lowLeafProof: _absence.imtProof
        });
        if (!absent) revert ProofNonInclusionFailed(_absence.chainImtRoot, _commitValue);

        // ── A3 (live branch): consecutive successor N+1, same chain & SL, with t_{N+1} > deadline ──
        (, uint256 slChainIdS, uint256 tS) = _authenticateRoot(_successor);
        if (slChainIdS != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainIdS);
        }
        if (_successor.sourceChainId != _absence.sourceChainId) {
            revert ProofSourceChainMismatch(_absence.sourceChainId, _successor.sourceChainId);
        }
        if (_successor.batchNumber != _absence.batchNumber + 1) {
            revert ProofAdjacencyNotConsecutive(_absence.batchNumber, _successor.batchNumber);
        }
        if (tS <= _deadline) {
            // Successor is still in time -> N is NOT the last in-time batch, so absence at N proves
            // nothing (the value could still be committed in a batch between N and the deadline). This is
            // exactly what defeats the stale/genesis-root force-refund.
            revert ProofDeadlineNotExceeded(tS, _deadline);
        }
    }

    /// @dev Reconstructs and authenticates the commitment tree's `(root)` L2->L1 message against the
    /// interop root imported for `(_sourceChainId, _batchNumber)`, AND derives the settlement-layer
    /// metadata — the SL snapshot block, the SL chain id, and the batch's settlement timestamp `t` — from
    /// the very same proof.
    ///
    /// Step 1 (auth, unchanged): build the {L2Message} (sender pinned to {L2_INTEROP_COMMITMENT_TREE_ADDR},
    /// identical on every chain — this binds the root to the real tree; the interop-root channel binds
    /// it to `_sourceChainId`) and verify inclusion via `proveL2MessageInclusionShared`. The `abi.encode`
    /// here must match what {L2InteropCommitmentTree} publishes.
    ///
    /// Step 2 (SL metadata): independently re-parse the same proof. We compute the identical leaf the
    /// verifier hashes (`getLeafHashFromLog(_l2MessageToLog(message))`) and run {MessageHashing._getProofData}
    /// over the same `(sourceChainId, batchNumber, messageIndex, leaf, messageProof)`. A single-level /
    /// commit-based proof (`finalProofNode == true`) carries no SL anchor, so we reject it; a multi-hop /
    /// SL-global proof exposes `pd.settlementLayerBatchNumber` (the SL snapshot block),
    /// `pd.settlementLayerChainId`, and `pd.batchSettlementTimestamp` (the authenticated `t`).
    ///
    /// @return slBlock The SL snapshot block `interopRoots(slChainId, slBlock)` was resolved at.
    /// @return slChainId The settlement-layer chain id (enforced equal to the flow's SL by callers).
    /// @return batchTimestamp The batch's SL-assigned settlement timestamp `t`, compared to the deadline.
    function _authenticateRoot(
        ImtProof calldata _proof
    ) private view returns (uint256 slBlock, uint256 slChainId, uint256 batchTimestamp) {
        L2Message memory message = L2Message({
            txNumberInBatch: _proof.messageTxNumberInBatch,
            sender: L2_INTEROP_COMMITMENT_TREE_ADDR,
            data: abi.encode(_proof.chainImtRoot)
        });
        bool ok = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
            _chainId: _proof.sourceChainId,
            _blockOrBatchNumber: _proof.batchNumber,
            _index: _proof.messageIndex,
            _message: message,
            _proof: _proof.messageProof
        });
        if (!ok) revert ProofRootMessageInclusionFailed(_proof.sourceChainId, _proof.batchNumber);

        // Re-parse the SAME proof to extract the SL metadata. The leaf is computed exactly as the verifier
        // does, so the parse is bound to the verified root.
        bytes32 leaf = MessageHashing.getLeafHashFromLog(MessageHashing._l2MessageToLog(message));
        ProofData memory pd = MessageHashing._getProofData({
            _chainId: _proof.sourceChainId,
            _batchNumber: _proof.batchNumber,
            _leafProofMask: _proof.messageIndex,
            _leaf: leaf,
            _proof: _proof.messageProof
        });
        // A final-node (single-level / commit-based) proof has no settlement-layer anchor; neither the
        // deadline nor `t` can be expressed against it.
        if (pd.finalProofNode) revert ProofMissingSettlementLayerAnchor(_proof.sourceChainId, _proof.batchNumber);

        slBlock = pd.settlementLayerBatchNumber;
        slChainId = pd.settlementLayerChainId;
        batchTimestamp = pd.batchSettlementTimestamp;
    }
}
