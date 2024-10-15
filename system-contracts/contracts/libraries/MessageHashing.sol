// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Merkle} from "./Merkle.sol";
import {SUPPORTED_PROOF_METADATA_VERSION} from "../Constants.sol";
import {MerklePathEmpty, BatchNotExecuted} from "../SystemContractErrors.sol";
import {UncheckedMath} from "./UncheckedMath.sol";

bytes32 constant BATCH_LEAF_PADDING = keccak256("zkSync:BatchLeaf");
bytes32 constant CHAIN_ID_LEAF_PADDING = keccak256("zkSync:ChainIdLeaf");

struct ProofVerificationResult {
    uint256 settlementLayerChainId;
    uint256 settlementLayerBatchNumber;
    uint256 settlementLayerBatchRootMask;
    uint256 batchLeafProofLen;
    bytes32 batchSettlementRoot;
    bytes32 chainIdLeaf;
    uint256 ptr;
}

library MessageHashing {
    using UncheckedMath for uint256;

    /// @dev Returns the leaf hash for a chain with batch number and batch root.
    /// @param batchRoot The root hash of the batch.
    /// @param batchNumber The number of the batch.
    function batchLeafHash(bytes32 batchRoot, uint256 batchNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(BATCH_LEAF_PADDING, batchRoot, batchNumber));
    }

    /// @dev Returns the leaf hash for a chain with chain root and chain id.
    /// @param chainIdRoot The root hash of the chain.
    /// @param chainId The id of the chain.
    function chainIdLeafHash(bytes32 chainIdRoot, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(CHAIN_ID_LEAF_PADDING, chainIdRoot, chainId));
    }

    function parseProofMetadata(
        bytes32[] memory _proof
    ) internal pure returns (uint256 proofStartIndex, uint256 logLeafProofLen, uint256 batchLeafProofLen) {
        bytes32 proofMetadata = _proof[0];

        // We support two formats of the proofs:
        // 1. The old format, where `_proof` is just a plain Merkle proof.
        // 2. The new format, where the first element of the `_proof` is encoded metadata, which consists of the following:
        // - first byte: metadata version (0x01).
        // - second byte: length of the log leaf proof (the proof that the log belongs to a batch).
        // - third byte: length of the batch leaf proof (the proof that the batch belongs to another settlement layer, if any).
        // - the rest of the bytes are zeroes.
        //
        // In the future the old version will be disabled, and only the new version will be supported.
        // For now, we need to support both for backwards compatibility. We distinguish between those based on whether the last 29 bytes are zeroes.
        // It is safe, since the elements of the proof are hashes and are unlikely to have 29 zero bytes in them.

        // We shift left by 3 bytes = 24 bits to remove the top 24 bits of the metadata.
        uint256 metadataAsUint256 = (uint256(proofMetadata) << 24);

        if (metadataAsUint256 == 0) {
            // It is the new version
            bytes1 metadataVersion = bytes1(proofMetadata);
            require(
                uint256(uint8(metadataVersion)) == SUPPORTED_PROOF_METADATA_VERSION,
                "Mailbox: unsupported proof metadata version"
            );

            proofStartIndex = 1;
            logLeafProofLen = uint256(uint8(proofMetadata[1]));
            batchLeafProofLen = uint256(uint8(proofMetadata[2]));
        } else {
            // It is the old version

            // The entire proof is a merkle path
            proofStartIndex = 0;
            logLeafProofLen = _proof.length;
            batchLeafProofLen = 0;
        }
    }

    function hashProof(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] memory _proof
    ) internal pure returns (ProofVerificationResult memory result) {
        if (_proof.length == 0) {
            revert MerklePathEmpty();
        }

        (uint256 proofStartIndex, uint256 logLeafProofLen, uint256 batchLeafProofLen) = MessageHashing
            .parseProofMetadata(_proof);
        result.ptr = proofStartIndex;

        {
            bytes32 batchSettlementRoot = Merkle.calculateRootMemory(
                extractSlice(_proof, result.ptr, result.ptr + logLeafProofLen),
                _leafProofMask,
                _leaf
            );
            result.ptr += logLeafProofLen;
            result.batchSettlementRoot = batchSettlementRoot;

            if (batchLeafProofLen == 0) {
                return result;
            }
            // Now, we'll have to check that the Gateway included the message.
            bytes32 localBatchLeafHash = MessageHashing.batchLeafHash(batchSettlementRoot, _batchNumber);

            uint256 batchLeafProofMask = uint256(bytes32(_proof[result.ptr]));
            ++result.ptr;

            bytes32 chainIdRoot = Merkle.calculateRootMemory(
                extractSlice(_proof, result.ptr, result.ptr + batchLeafProofLen),
                batchLeafProofMask,
                localBatchLeafHash
            );
            result.ptr += batchLeafProofLen;

            result.chainIdLeaf = MessageHashing.chainIdLeafHash(chainIdRoot, _chainId);
        }
        uint256 settlementLayerChainId;
        uint256 settlementLayerBatchNumber;
        uint256 settlementLayerBatchRootMask;
        // Preventing stack too deep error
        {
            // Now, we just need to double check whether this chainId leaf was present in the tree.
            uint256 settlementLayerPackedBatchInfo = uint256(_proof[result.ptr]);
            ++result.ptr;
            settlementLayerBatchNumber = uint256(settlementLayerPackedBatchInfo >> 128);
            settlementLayerBatchRootMask = uint256(settlementLayerPackedBatchInfo & ((1 << 128) - 1));

            settlementLayerChainId = uint256(_proof[result.ptr]);
            ++result.ptr;
        }

        result = ProofVerificationResult({
            settlementLayerChainId: settlementLayerChainId,
            settlementLayerBatchNumber: settlementLayerBatchNumber,
            settlementLayerBatchRootMask: settlementLayerBatchRootMask,
            batchLeafProofLen: batchLeafProofLen,
            batchSettlementRoot: result.batchSettlementRoot,
            chainIdLeaf: result.chainIdLeaf,
            ptr: result.ptr
        });
    }

    function extractSlice(
        bytes32[] memory _proof,
        uint256 _left,
        uint256 _right
    ) internal pure returns (bytes32[] memory slice) {
        slice = new bytes32[](_right - _left);
        for (uint256 i = _left; i < _right; i = i.uncheckedInc()) {
            slice[i - _left] = _proof[i];
        }
    }

    /// @notice Extracts slice until the end of the array.
    /// @dev It is used in one place in order to circumvent the stack too deep error.
    function extractSliceUntilEnd(
        bytes32[] memory _proof,
        uint256 _start
    ) internal pure returns (bytes32[] memory slice) {
        slice = extractSlice(_proof, _start, _proof.length);
    }
}
