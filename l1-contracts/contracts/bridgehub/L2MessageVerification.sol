// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {MessageVerification} from "../state-transition/chain-deps/facets/MessageVerification.sol";
import {MessageHashing, ProofVerificationResult} from "../common/libraries/MessageHashing.sol";
import {L2_MESSAGE_ROOT_STORAGE_ADDRESS} from "../common/l2-helpers/L2ContractAddresses.sol";
import {NotL1, UnsupportedProofMetadataVersion, LocalRootIsZero, LocalRootMustBeZero, NotSettlementLayer, NotHyperchain} from "../state-transition/L1StateTransitionErrors.sol";

contract L2MessageVerification is MessageVerification {
    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal view override returns (bool) {
        ProofVerificationResult memory proofVerificationResult = MessageHashing.hashProof(
            _chainId,
            _batchNumber,
            _leafProofMask,
            _leaf,
            _proof
        );
        if (proofVerificationResult.finalProofNode) {
            bytes32 correctBatchRoot = L2_MESSAGE_ROOT_STORAGE_ADDRESS.msgRoots(_chainId, _batchNumber);
            return true; // kl todo.

            // if (correctBatchRoot == bytes32(0)) {
            //     revert LocalRootIsZero();
            // }
            // return correctBatchRoot == proofVerificationResult.batchSettlementRoot;
        }

        return
            this.proveL2LeafInclusionShared(
                proofVerificationResult.settlementLayerChainId,
                proofVerificationResult.settlementLayerBatchNumber,
                proofVerificationResult.settlementLayerBatchRootMask,
                proofVerificationResult.chainIdLeaf,
                MessageHashing.extractSliceUntilEnd(_proof, proofVerificationResult.ptr)
            );
    }
}
