// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {MessageVerification} from "../common/MessageVerification.sol";
import {MessageHashing, ProofData} from "../common/libraries/MessageHashing.sol";
import {L2_INTEROP_ROOT_STORAGE} from "../common/l2-helpers/L2ContractAddresses.sol";
import {DepthMoreThanOneForRecursiveMerkleProof} from "../core/bridgehub/L1BridgehubErrors.sol";

/// @title The interface of the ZKsync L2MessageVerification contract that can be used to prove L2 message inclusion on the L2.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L2MessageVerification is MessageVerification {
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
            // For proof based interop this is the SL InteropRoot at block number _blockOrBatchNumber
            bytes32 correctBatchRoot = L2_INTEROP_ROOT_STORAGE.interopRoots(_chainId, _blockOrBatchNumber);
            return correctBatchRoot == proofData.batchSettlementRoot && correctBatchRoot != bytes32(0);
        }
        if (_depth == 1) {
            revert DepthMoreThanOneForRecursiveMerkleProof();
        }

        // Note that here we assume that all settlement layers that the chain has ever settled on are trustworthy,
        // i.e. all chains inside the ecosystem trust that they will not accept a message for a batch
        // that never happened.

        return
            this.proveL2LeafInclusionSharedRecursive({
                _chainId: proofData.settlementLayerChainId,
                _blockOrBatchNumber: proofData.settlementLayerBatchNumber, // SL block number
                _leafProofMask: proofData.settlementLayerBatchRootMask,
                _leaf: proofData.chainIdLeaf,
                _proof: MessageHashing.extractSliceUntilEnd(_proof, proofData.ptr),
                _depth: _depth + 1
            });
    }
}
