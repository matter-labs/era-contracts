// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {MessageVerification} from "../state-transition/chain-deps/facets/MessageVerification.sol";
import {MessageHashing, ProofData} from "../common/libraries/MessageHashing.sol";
import {L2_INTEROP_ROOT_STORAGE} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @title The interface of the ZKsync L2MessageVerification contract that can be used to prove L2 message inclusion on the L2.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L2MessageVerification is MessageVerification {
    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
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

        return
            this.proveL2LeafInclusionShared({
                _chainId: proofData.settlementLayerChainId,
                _blockOrBatchNumber: proofData.settlementLayerBatchNumber, // SL block number
                _leafProofMask: proofData.settlementLayerBatchRootMask,
                _leaf: proofData.chainIdLeaf,
                _proof: MessageHashing.extractSliceUntilEnd(_proof, proofData.ptr)
            });
    }
}
