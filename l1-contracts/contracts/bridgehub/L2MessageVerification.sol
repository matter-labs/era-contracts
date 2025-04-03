// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {MessageVerification} from "../state-transition/chain-deps/facets/MessageVerification.sol";
import {MessageHashing, ProofVerificationResult} from "../common/libraries/MessageHashing.sol";
import {L2_MESSAGE_ROOT_STORAGE} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @title The interface of the ZKsync L2MessageVerification contract that can be used to prove L2 message inclusion on the L2.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L2MessageVerification is MessageVerification {
    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal view override returns (bool) {
        ProofVerificationResult memory proofVerificationResult = MessageHashing.hashProof({
            _chainId: _chainId,
            _batchNumber: _batchNumber,
            _leafProofMask: _leafProofMask,
            _leaf: _leaf,
            _proof: _proof
        });
        if (proofVerificationResult.finalProofNode) {
            bytes32 correctBatchRoot = L2_MESSAGE_ROOT_STORAGE.msgRoots(_chainId, _batchNumber);
            return correctBatchRoot == proofVerificationResult.batchSettlementRoot;
        }
        // kl todo think this through. Does it work for the global MessageRoot, and for GW based chains, and both?
        return
            this.proveL2LeafInclusionShared({
                _chainId: proofVerificationResult.settlementLayerChainId,
                _batchNumber: proofVerificationResult.settlementLayerBatchNumber,
                _leafProofMask: proofVerificationResult.settlementLayerBatchRootMask,
                _leaf: proofVerificationResult.chainIdLeaf,
                _proof: MessageHashing.extractSliceUntilEnd(_proof, proofVerificationResult.ptr)
            });
    }
}
