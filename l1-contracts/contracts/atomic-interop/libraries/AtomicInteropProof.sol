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
    ProofNonInclusionFailed
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
/// The flow `deadline` is a **settlement-layer (SL) block number**. It is NOT carried in the proof
/// struct (that would be spoofable); instead it is **derived from the same multi-hop proof** the
/// message verifier checks. We independently re-parse `messageProof` with {MessageHashing._getProofData}
/// (computing the identical leaf the verifier uses) and read `pd.settlementLayerBatchNumber` — which is
/// exactly the SL block the verifier resolved `interopRoots(SL, slBlock)` against, because both parse
/// the same `(sourceChainId, batchNumber, messageIndex, leaf, messageProof)`. That binding is the whole
/// point: the SL block is provably the one whose imported root authenticated the IMT root.
///
/// Single-settlement-layer assumption: a flow's `deadline` is comparable across legs only if all legs
/// settle on the same SL, so their `settlementLayerBatchNumber`s share a scale. `slChainId`
/// (`pd.settlementLayerChainId`) is returned so a caller may assert consistency across a flow's proofs.
///
/// Membership (inclusion) and non-membership (low-nullifier) against the authenticated root are
/// delegated to {IndexedMerkleTree}, the single shared IMT engine.
library AtomicInteropProof {
    /// @notice The value inserted into a chain's IMT when a flow leg is committed.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Verifies `_commitValue` is present in `_proof.sourceChainId`'s IMT as of an
    /// authenticated root whose settlement-layer block number is `<= _deadline`.
    /// @dev The proof is bound to the correct chain by `_commitValue` itself: it bakes in the
    /// chain-specific `bundleHash`, so a leg's commit value can only ever be inserted into its own
    /// source chain's tree — the membership check below therefore can only pass against that chain.
    function verifyInclusion(ImtProof calldata _proof, uint256 _commitValue, uint64 _deadline) internal view {
        // solhint-disable-next-line func-named-parameters
        (uint256 slBlock, ) = _authenticateRoot(
            _proof.sourceChainId,
            _proof.batchNumber,
            _proof.chainImtRoot,
            _proof.messageTxNumberInBatch,
            _proof.messageIndex,
            _proof.messageProof
        );
        if (slBlock > _deadline) {
            revert ProofDeadlineExceeded(slBlock, _deadline);
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

    /// @notice Verifies `_commitValue` is absent from `_proof.sourceChainId`'s IMT as of an
    /// authenticated root whose settlement-layer block number is `> _deadline` — so the leg can no
    /// longer be committed in time and the flow cannot finalize.
    /// @dev As in {verifyInclusion}, `_commitValue` is chain-specific (it bakes in the chain-specific
    /// `bundleHash`), so the non-inclusion check is meaningful only against the leg's own source chain.
    function verifyNonInclusion(ImtProof calldata _proof, uint256 _commitValue, uint64 _deadline) internal view {
        // solhint-disable-next-line func-named-parameters
        (uint256 slBlock, ) = _authenticateRoot(
            _proof.sourceChainId,
            _proof.batchNumber,
            _proof.chainImtRoot,
            _proof.messageTxNumberInBatch,
            _proof.messageIndex,
            _proof.messageProof
        );
        if (slBlock <= _deadline) {
            revert ProofDeadlineNotExceeded(slBlock, _deadline);
        }
        bool absent = IndexedMerkleTree.verifyNonInclusion({
            _root: _proof.chainImtRoot,
            _value: _commitValue,
            _lowLeaf: _proof.leaf,
            _lowLeafIndex: _proof.imtLeafIndex,
            _lowLeafProof: _proof.imtProof
        });
        if (!absent) revert ProofNonInclusionFailed(_proof.chainImtRoot, _commitValue);
    }

    /// @dev Reconstructs and authenticates the commitment tree's `(root)` L2->L1 message against the
    /// interop root imported for `(_sourceChainId, _batchNumber)`, AND derives the settlement-layer
    /// block number the root settled at from the very same proof.
    ///
    /// Step 1 (auth, unchanged): build the {L2Message} (sender pinned to {L2_INTEROP_COMMITMENT_TREE_ADDR},
    /// identical on every chain — this binds the root to the real tree; the interop-root channel binds
    /// it to `_sourceChainId`) and verify inclusion via `proveL2MessageInclusionShared`. The `abi.encode`
    /// here must match what {L2InteropCommitmentTree} publishes.
    ///
    /// Step 2 (SL block): independently re-parse the same proof. We compute the identical leaf the
    /// verifier hashes (`getLeafHashFromLog(_l2MessageToLog(message))`) and run {MessageHashing._getProofData}
    /// over the same `(_sourceChainId, _batchNumber, _messageIndex, leaf, _messageProof)`. A single-level /
    /// commit-based proof (`finalProofNode == true`) carries no SL block, so we reject it; a multi-hop /
    /// SL-global proof exposes `pd.settlementLayerBatchNumber` (the SL block) and `pd.settlementLayerChainId`.
    ///
    /// @return slBlock The settlement-layer block number `interopRoots(slChainId, slBlock)` was resolved at.
    /// @return slChainId The settlement-layer chain id (returned for cross-leg consistency checks).
    function _authenticateRoot(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        bytes32 _chainImtRoot,
        uint16 _messageTxNumberInBatch,
        uint256 _messageIndex,
        bytes32[] calldata _messageProof
    ) private view returns (uint256 slBlock, uint256 slChainId) {
        L2Message memory message = L2Message({
            txNumberInBatch: _messageTxNumberInBatch,
            sender: L2_INTEROP_COMMITMENT_TREE_ADDR,
            data: abi.encode(_chainImtRoot)
        });
        bool ok = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
            _chainId: _sourceChainId,
            _blockOrBatchNumber: _batchNumber,
            _index: _messageIndex,
            _message: message,
            _proof: _messageProof
        });
        if (!ok) revert ProofRootMessageInclusionFailed(_sourceChainId, _batchNumber);

        // Re-parse the SAME proof to extract the SL block. The leaf is computed exactly as the verifier
        // does, so the parse is bound to the verified root.
        bytes32 leaf = MessageHashing.getLeafHashFromLog(MessageHashing._l2MessageToLog(message));
        ProofData memory pd = MessageHashing._getProofData({
            _chainId: _sourceChainId,
            _batchNumber: _batchNumber,
            _leafProofMask: _messageIndex,
            _leaf: leaf,
            _proof: _messageProof
        });
        // A final-node (single-level / commit-based) proof has no settlement-layer anchor; the deadline
        // cannot be expressed against it.
        if (pd.finalProofNode) revert ProofMissingSettlementLayerAnchor(_sourceChainId, _batchNumber);

        slBlock = pd.settlementLayerBatchNumber;
        slChainId = pd.settlementLayerChainId;
    }
}
