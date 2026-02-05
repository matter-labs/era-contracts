// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Merkle} from "./Merkle.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, SUPPORTED_PROOF_METADATA_VERSION} from "../Config.sol";
import {MerklePathEmpty} from "../L1ContractErrors.sol";
import {UncheckedMath} from "./UncheckedMath.sol";
import {L2Log, L2Message, ProofData, TxStatus} from "../Messaging.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../l2-helpers/L2ContractAddresses.sol";

import {UnsupportedProofMetadataVersion} from "../../state-transition/L1StateTransitionErrors.sol";
import {HashedLogIsDefault, InvalidProofLengthForFinalNode} from "../../common/L1ContractErrors.sol";

bytes32 constant BATCH_LEAF_PADDING = keccak256("zkSync:BatchLeaf");
bytes32 constant CHAIN_ID_LEAF_PADDING = keccak256("zkSync:ChainIdLeaf");

library MessageHashing {
    using UncheckedMath for uint256;

    function getLeafHashFromMessage(L2Message memory _message) internal pure returns (bytes32 hashedLog) {
        L2Log memory l2Log = _l2MessageToLog(_message);
        hashedLog = getLeafHashFromLog(l2Log);
    }

    /// @dev Convert arbitrary-length message to the raw L2 log
    function _l2MessageToLog(L2Message memory _message) internal pure returns (L2Log memory) {
        return
            L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBatch: _message.txNumberInBatch,
                sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                key: bytes32(uint256(uint160(_message.sender))),
                value: keccak256(_message.data)
            });
    }

    function getL2LogFromL1ToL2Transaction(
        uint16 _l2TxNumberInBatch,
        bytes32 _l2TxHash,
        TxStatus _status
    ) internal pure returns (L2Log memory l2Log) {
        // Bootloader sends an L2 -> L1 log only after processing the L1 -> L2 transaction.
        // Thus, we can verify that the L1 -> L2 transaction was included in the L2 batch with specified status.
        //
        // The semantics of such L2 -> L1 log is always:
        // - sender = L2_BOOTLOADER_ADDRESS
        // - key = hash(L1ToL2Transaction)
        // - value = status of the processing transaction (1 - success & 0 - fail)
        // - isService = true (just a conventional value)
        // - l2ShardId = 0 (means that L1 -> L2 transaction was processed in a rollup shard, other shards are not available yet anyway)
        // - txNumberInBatch = number of transaction in the batch
        l2Log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: _l2TxNumberInBatch,
            sender: L2_BOOTLOADER_ADDRESS,
            key: _l2TxHash,
            value: bytes32(uint256(_status))
        });
    }

    function getLeafHashFromLog(L2Log memory _log) internal pure returns (bytes32 hashedLog) {
        hashedLog = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(_log.l2ShardId, _log.isService, _log.txNumberInBatch, _log.sender, _log.key, _log.value)
        );
    }

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

    struct ProofMetadata {
        uint256 proofStartIndex;
        uint256 logLeafProofLen;
        uint256 batchLeafProofLen;
        bool finalProofNode;
    }

    /// @notice Parses the proof metadata.
    /// @param _proof The proof.
    /// @return result The proof metadata.
    function parseProofMetadata(bytes32[] calldata _proof) internal pure returns (ProofMetadata memory result) {
        bytes32 proofMetadata = _proof[0];

        // We support two formats of the proofs:
        // 1. The old format, where `_proof` is just a plain Merkle proof.
        // 2. The new format, where the first element of the `_proof` is encoded metadata, which consists of the following:
        // - first byte: metadata version (0x01).
        // - second byte: length of the log leaf proof (the proof that the log belongs to a batch).
        // - third byte: length of the batch leaf proof (the proof that the batch belongs to another settlement layer, if any).
        // - fourth byte: whether the current proof is the last in the links of recursive proofs for settlement layers.
        // - the rest of the bytes are zeroes.
        //
        // In the future the old version will be disabled, and only the new version will be supported.
        // For now, we need to support both for backwards compatibility. We distinguish between those based on whether the last 28 bytes are zeroes.
        // It is safe, since the elements of the proof are hashes and are unlikely to have 28 zero bytes in them.

        // We shift left by 4 bytes = 32 bits to remove the top 32 bits of the metadata.
        uint256 metadataAsUint256 = (uint256(proofMetadata) << 32);

        if (metadataAsUint256 == 0) {
            // It is the new version
            bytes1 metadataVersion = bytes1(proofMetadata);
            if (uint256(uint8(metadataVersion)) != SUPPORTED_PROOF_METADATA_VERSION) {
                revert UnsupportedProofMetadataVersion(uint256(uint8(metadataVersion)));
            }

            result.proofStartIndex = 1;
            result.logLeafProofLen = uint256(uint8(proofMetadata[1]));
            result.batchLeafProofLen = uint256(uint8(proofMetadata[2]));
            result.finalProofNode = uint256(uint8(proofMetadata[3])) != 0;
        } else {
            // It is the old version

            // The entire proof is a merkle path
            result.proofStartIndex = 0;
            result.logLeafProofLen = _proof.length;
            result.batchLeafProofLen = 0;
            result.finalProofNode = true;
        }
        if (result.finalProofNode && result.batchLeafProofLen != 0) {
            revert InvalidProofLengthForFinalNode();
        }
    }

    /// @notice Parses and processes the proof and returns the resulting data.
    /// @param _chainId The chain id of the L2 where the leaf comes from.
    /// @param _batchNumber The batch number.
    /// @param _leafProofMask The leaf proof mask.
    /// @param _leaf The leaf to be proven.
    /// @param _proof The proof.
    /// @return result The proof verification result.
    function _getProofData(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal pure returns (ProofData memory result) {
        if (_proof.length == 0) {
            revert MerklePathEmpty();
        }

        // Check that hashed log is not the default one,
        // otherwise it means that the value is out of range of sent L2 -> L1 logs
        if (_leaf == L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH) {
            revert HashedLogIsDefault();
        }

        ProofMetadata memory proofMetadata = MessageHashing.parseProofMetadata(_proof);
        result.ptr = proofMetadata.proofStartIndex;

        {
            bytes32 batchSettlementRoot = Merkle.calculateRootMemory(
                extractSlice(_proof, result.ptr, result.ptr + proofMetadata.logLeafProofLen),
                _leafProofMask,
                _leaf
            );
            result.ptr += proofMetadata.logLeafProofLen;
            result.batchSettlementRoot = batchSettlementRoot;
            result.finalProofNode = proofMetadata.finalProofNode;

            if (proofMetadata.finalProofNode) {
                return result;
            }
            // Now, we'll have to check that the Gateway included the message.
            bytes32 localBatchLeafHash = MessageHashing.batchLeafHash(batchSettlementRoot, _batchNumber);

            uint256 batchLeafProofMask = uint256(bytes32(_proof[result.ptr]));
            ++result.ptr;

            bytes32 chainIdRoot = Merkle.calculateRootMemory(
                extractSlice(_proof, result.ptr, result.ptr + proofMetadata.batchLeafProofLen),
                batchLeafProofMask,
                localBatchLeafHash
            );
            result.ptr += proofMetadata.batchLeafProofLen;

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

        result = ProofData({
            settlementLayerChainId: settlementLayerChainId,
            settlementLayerBatchNumber: settlementLayerBatchNumber,
            settlementLayerBatchRootMask: settlementLayerBatchRootMask,
            batchLeafProofLen: proofMetadata.batchLeafProofLen,
            batchSettlementRoot: result.batchSettlementRoot,
            chainIdLeaf: result.chainIdLeaf,
            ptr: result.ptr,
            finalProofNode: proofMetadata.finalProofNode
        });
    }

    /// @notice Extracts slice from the proof.
    /// @param _proof The proof.
    /// @param _left The left index.
    /// @param _right The right index.
    /// @return slice The slice.
    function extractSlice(
        bytes32[] calldata _proof,
        uint256 _left,
        uint256 _right
    ) internal pure returns (bytes32[] memory slice) {
        slice = new bytes32[](_right - _left);
        for (uint256 i = _left; i < _right; ++i) {
            slice[i - _left] = _proof[i];
        }
    }

    /// @notice Extracts slice until the end of the array.
    /// @dev It is used in one place in order to circumvent the stack too deep error.
    function extractSliceUntilEnd(
        bytes32[] calldata _proof,
        uint256 _start
    ) internal pure returns (bytes32[] memory slice) {
        slice = extractSlice(_proof, _start, _proof.length);
    }
}
