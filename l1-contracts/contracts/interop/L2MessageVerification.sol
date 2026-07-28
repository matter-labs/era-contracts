// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {MessageVerification} from "../common/MessageVerification.sol";
import {MessageHashing, ProofData} from "../common/libraries/MessageHashing.sol";
import {L2_INTEROP_ROOT_STORAGE} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {DepthMoreThanOneForRecursiveMerkleProof} from "../core/bridgehub/L1BridgehubErrors.sol";

/// @title L2MessageVerification
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Proves L2->L1 message inclusion on an L2, anchoring the shared recursive proof logic to
/// the imported interop roots. See {protocol-docs/interop.md#message-verification-l2messageverification}.
contract L2MessageVerification is MessageVerification {
    /// @dev Overrides the shared recursion with the L2 terminal step; recursion depth is limited to
    /// one hop.
    function _proveL2LeafInclusionRecursive(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof,
        uint256 _depth
    ) internal view override returns (bool) {
        ProofData memory proofData = MessageHashing._getProofData({
            _chainId: _chainId,
            _batchNumber: _blockOrBatchNumber,
            _leafProofMask: _leafProofMask,
            _leaf: _leaf,
            _proof: _proof
        });
        if (proofData.finalProofNode) {
            // finalProofNode terminates on an L2 consumer: it anchors to the imported L1 aggregate interop
            // root (`interopRoots`), since an L2 has no per-chain roots. (On L1 — the settlement layer of
            // every chain in this release — `MessageRootBase` terminates at its own `chainBatchRoots`.)
            bytes32 correctBatchRoot = L2_INTEROP_ROOT_STORAGE.interopRoots(_chainId, _blockOrBatchNumber).root;
            return correctBatchRoot == proofData.batchSettlementRoot && correctBatchRoot != bytes32(0);
        }
        if (_depth == 1) {
            revert DepthMoreThanOneForRecursiveMerkleProof();
        }

        // Assumes all settlement layers the chain has ever settled on are trustworthy (see
        // {protocol-docs/interop.md#message-verification-l2messageverification}).
        return
            this.proveL2LeafInclusionSharedRecursive({
                _chainId: proofData.settlementLayerChainId,
                // Here we use SL *block* number, NOT batch number
                _blockOrBatchNumber: proofData.settlementLayerBatchNumber,
                _leafProofMask: proofData.settlementLayerBatchRootMask,
                _leaf: proofData.chainIdLeaf,
                _proof: MessageHashing.extractSliceUntilEnd(_proof, proofData.ptr),
                _depth: _depth + 1
            });
    }
}
