// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {MessageVerification} from "./DummyMessageVerification.sol";
import {MessageHashing, ProofData} from "./libraries/MessageHashing.sol";
import {L2_INTEROP_ROOT_STORAGE} from "../Constants.sol";

contract DummyL2MessageVerification is MessageVerification {
    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal view override returns (bool) {
        ProofData memory proofVerificationResult = MessageHashing.hashProof(
            _chainId,
            _batchNumber,
            _leafProofMask,
            _leaf,
            _proof
        );
        if (proofVerificationResult.finalProofNode) {
            bytes32 correctBatchRoot = L2_INTEROP_ROOT_STORAGE.msgRoots(_chainId, _batchNumber);
            return correctBatchRoot == proofVerificationResult.batchSettlementRoot;
        }
        // kl todo think this through. Does it work for the global MessageRoot, and for GW based chains, and both?
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
