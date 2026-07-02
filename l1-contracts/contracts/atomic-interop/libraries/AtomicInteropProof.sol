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
/// messenger. The verifying chain authenticates that single message against an imported SL
/// aggregation root: the accepted (multi-hop) proof terminates at `interopRoots[slChainId][slBlock]`
/// and binds the message to `sourceChainId` via that chain's chain-id leaf inside the SL root —
/// which the verifier only holds once the source batch has settled, so the root cannot be forged.
///
/// The flow `deadline` is a settlement-layer timestamp. It is not carried in the proof struct
/// (that would be spoofable); instead each batch's `l1Timestamp` — the settlement-layer block
/// timestamp at which the batch root was aggregated (`t` in the inequalities below) — is derived
/// from the same proof the message verifier checks. We re-parse `messageProof` with
/// {MessageHashing._getProofData} (computing the same leaf the verifier uses) and read
/// `pd.l1BatchTimestamp`. It is authenticated because it is folded into the chain batch leaf
/// ({MessageHashing.batchLeafHash}), so it cannot be forged without breaking the chainId /
/// shared-tree path. The same parse also gives `pd.settlementLayerChainId` and
/// `pd.settlementLayerBatchNumber` (the SL snapshot block the root resolved `interopRoots` against).
///
/// A flow's `deadline` and `t` are only comparable if all legs settle on the same settlement layer,
/// so {verifyInclusion} / {verifyTimeoutAdjacency} require the resolved `slChainId` to equal the
/// flow's `settlementLayerChainId` (else {ProofSettlementLayerMismatch}).
///
/// A leg times out iff its commit value is absent from the last batch `N` with `t_N <= deadline`.
/// {verifyTimeoutAdjacency} proves absence at `N` (with `t_N <= deadline`) and that the consecutive
/// successor batch `N+1` (same source chain, same SL) has `t_{N+1} > deadline`, pinning `N` as the
/// last in-time batch. This blocks a force-refund off a stale/genesis root (an old/empty root's
/// successor would still be `<= deadline`) while keeping a genuine no-show refundable.
/// TODO: add a halt branch that restores refund liveness for a halted source with no successor
/// batch; it needs a "highest-leaf" SL chain-tree proof not yet exposed by proveL2MessageInclusionShared.
/// TODO: a source with NO settled batch with `t <= deadline` (first-ever settlement lands after the
/// deadline) is a second refund-liveness gap: absence needs a batch `N` with `t_N <= deadline`, so a
/// no-show there is neither finalizable nor refundable and counterparties' committed legs lock. Until
/// a first-batch variant exists (prove the chain's first batch has `t > deadline`), flow builders must
/// only include legs on chains that already have a settled batch (any chain settled before flow
/// creation qualifies).
///
/// Membership (inclusion) and non-membership (low-nullifier) against the authenticated root are
/// delegated to {IndexedMerkleTree}, the single shared IMT engine.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` is present in `_proof.sourceChainId`'s IMT as of an authenticated
    /// root whose batch settled on `_expectedSlChainId` with `l1Timestamp <= _deadline`.
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
        (, uint256 slChainId, uint256 batchTimestamp) = _authenticateRoot(_proof);
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

    /// @notice Timeout proof: shows `_commitValue` can no longer be committed in time and the flow
    /// cannot finalize, by proving it absent from the last batch with `t <= _deadline` on the source
    /// chain, pinned by the consecutive successor witness.
    ///   - `_absence` authenticates batch `N` with `t_N <= _deadline`, and `_commitValue` is absent
    ///     (low-nullifier non-inclusion) from `N`'s IMT root.
    ///   - `_successor` authenticates the consecutive batch `N+1` on the same source chain and SL with
    ///     `t_{N+1} > _deadline`, so `N` is the last in-time batch.
    /// The caller (authorizeRefund) checks `_proof.sourceChainId == legSourceChainIds[i]`; the SL match
    /// is checked here. Per-chain append-only trees plus monotone `t` mean any value in a batch with
    /// `t <= _deadline` is also in `N`, so this can't succeed for an on-time leg.
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
        // Absence at batch N, with t_N <= deadline.
        (, uint256 slChainIdN, uint256 tN) = _authenticateRoot(_absence);
        if (slChainIdN != _expectedSlChainId) {
            revert ProofSettlementLayerMismatch(_expectedSlChainId, slChainIdN);
        }
        if (tN > _deadline) {
            // Batch N is itself past the deadline, so it can't bound the value's commit window; reject.
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

        // Consecutive successor N+1, same chain & SL, with t_{N+1} > deadline.
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
            // Successor is still in time, so N isn't the last in-time batch and absence at N proves
            // nothing (the value could still land in a batch between N and the deadline). This is what
            // blocks a force-refund off a stale/genesis root.
            revert ProofDeadlineNotExceeded(tS, _deadline);
        }
    }

    /// @dev Authenticates the commitment tree's `(root)` L2->L1 message for `(_sourceChainId,
    /// _batchNumber)` against the imported SL aggregation root — the accepted (multi-hop) proof
    /// terminates at `interopRoots[slChainId][slBlock]`, with the source chain bound via its chain-id
    /// leaf inside that root — and derives the settlement-layer metadata (SL snapshot block, SL chain
    /// id, and the batch's `l1Timestamp`) from that same proof.
    ///
    /// Step 1 (auth, unchanged): build the {L2Message} (sender pinned to {L2_INTEROP_COMMITMENT_TREE_ADDR},
    /// identical on every chain — this binds the root to the real tree; the chain-id leaf binds it to
    /// `_sourceChainId`) and verify inclusion via `proveL2MessageInclusionShared`. The `abi.encode`
    /// here must match what {L2InteropCommitmentTree} publishes.
    ///
    /// Step 2: re-parse the same proof to read the SL metadata. We compute the same leaf the verifier
    /// hashes and run {MessageHashing._getProofData} over the same inputs. A single-level / commit-based
    /// proof (`finalProofNode == true`) carries no SL anchor, so we reject it; a multi-hop proof exposes
    /// `pd.settlementLayerBatchNumber`, `pd.settlementLayerChainId`, and `pd.l1BatchTimestamp`.
    ///
    /// @return slBlock The SL snapshot block `interopRoots(slChainId, slBlock)` was resolved at.
    /// @return slChainId The settlement-layer chain id (callers require it to equal the flow's SL).
    /// @return batchTimestamp The batch's `l1Timestamp`, compared to the deadline.
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

        // Re-parse the same proof for the SL metadata. The leaf is computed exactly as the verifier does,
        // so the parse is bound to the verified root.
        bytes32 leaf = MessageHashing.getLeafHashFromLog(MessageHashing._l2MessageToLog(message));
        ProofData memory pd = MessageHashing._getProofData({
            _chainId: _proof.sourceChainId,
            _batchNumber: _proof.batchNumber,
            _leafProofMask: _proof.messageIndex,
            _leaf: leaf,
            _proof: _proof.messageProof
        });
        // A final-node (single-level / commit-based) proof has no settlement-layer anchor, so neither the
        // deadline nor `t` can be checked against it.
        if (pd.finalProofNode) revert ProofMissingSettlementLayerAnchor(_proof.sourceChainId, _proof.batchNumber);

        slBlock = pd.settlementLayerBatchNumber;
        slChainId = pd.settlementLayerChainId;
        batchTimestamp = pd.l1BatchTimestamp;
    }
}
