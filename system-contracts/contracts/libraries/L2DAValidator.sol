// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {COMPRESSOR_CONTRACT, PUBDATA_CHUNK_PUBLISHER, L2DACommitmentScheme, STATE_DIFF_ENTRY_SIZE, L2_TO_L1_LOG_SERIALIZE_SIZE, STATE_DIFF_COMPRESSION_VERSION_NUMBER} from "../Constants.sol";
import {EfficientCall} from "../libraries/EfficientCall.sol";
import {ReconstructionMismatch, PubdataField, InvalidDACommitmentScheme} from "../SystemContractErrors.sol";
import {Utils} from "./Utils.sol";

/// TODO
library L2DAValidator {
    // TODO misleading name
    function validatePubdata(
        L2DACommitmentScheme _l2DACommitmentScheme,
        bytes32 _chainedMessagesHash,
        bytes32 _chainedBytecodesHash,
        bytes calldata _operatorData
    ) internal returns (bytes32 outputHash) {
        if (_l2DACommitmentScheme == L2DACommitmentScheme.EMPTY) {
            // Since we do not need to publish anything to L1, we can just return 0.
            // Note, that Rollup validator sends the hash of uncompressed state diffs, since the
            // correctness of the publish pubdata depends on it. However Validium doesn't sent anything,
            // so we don't need to publish even that.
            return bytes32(0);
        }

        (bytes32 stateDiffHash, bytes calldata _totalPubdata, bytes calldata leftover) = _produceStateDiffPubdata(
            _chainedMessagesHash,
            _chainedBytecodesHash,
            _operatorData
        );

        // TODO comments
        if (_l2DACommitmentScheme == L2DACommitmentScheme.ROLLUP) {
            /// Rollup DA commitment scheme. It will publish data that would allow to use either calldata or blobs.

            /// Check for calldata strict format
            if (leftover.length != 0) {
                revert ReconstructionMismatch(PubdataField.ExtraData, bytes32(0), bytes32(leftover.length));
            }

            // The preimage under the hash `outputHash` is expected to be in the following format:
            // - First 32 bytes are the hash of the uncompressed state diff.
            // - Then, there is a 32-byte hash of the full pubdata.
            // - Then, there is the 1-byte number of blobs published.
            // - Then, there are linear hashes of the published blobs, 32 bytes each.

            bytes32[] memory blobLinearHashes = PUBDATA_CHUNK_PUBLISHER.chunkPubdataToBlobs(_totalPubdata);

            outputHash = keccak256(
                abi.encodePacked(
                    stateDiffHash,
                    EfficientCall.keccak(_totalPubdata),
                    Utils.safeCastToU8(blobLinearHashes.length),
                    blobLinearHashes
                )
            );
        } else if (_l2DACommitmentScheme == L2DACommitmentScheme.KECCAK) {
            // It will create a commitment to the pubdata that can later be verified during settlement.

            bytes32 fullPubdataHash = EfficientCall.keccak(_totalPubdata);
            outputHash = keccak256(abi.encodePacked(stateDiffHash, fullPubdataHash));
        } else {
            revert InvalidDACommitmentScheme(uint256(_l2DACommitmentScheme));
        }
    }

    /// @notice Validates, that the operator provided the correct preimages for logs, messages, and bytecodes.
    /// @return uncompressedStateDiffHash the hash of the uncompressed state diffs
    /// @return totalL2Pubdata total pubdata that should be sent to L1.
    /// @return leftoverSuffix the suffix left after pubdata and uncompressed state diffs.
    /// On Era or other "vanilla" rollups it is empty, but it can be used for providing additional data by the operator,
    /// e.g. DA committee signatures, etc.
    function _produceStateDiffPubdata(
        bytes32 _chainedMessagesHash,
        bytes32 _chainedBytecodesHash,
        bytes calldata _totalL2ToL1PubdataAndStateDiffs
    )
        internal
        returns (bytes32 uncompressedStateDiffHash, bytes calldata totalL2Pubdata, bytes calldata leftoverSuffix)
    {
        uint256 calldataPtr = 0;

        /// Check logs
        {
            uint32 numberOfL2ToL1Logs = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
            calldataPtr += 4 + numberOfL2ToL1Logs * L2_TO_L1_LOG_SERIALIZE_SIZE;
        }

        /// Check messages
        {
            uint32 numberOfMessages = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
            calldataPtr += 4;
            bytes32 reconstructedChainedMessagesHash;
            for (uint256 i = 0; i < numberOfMessages; ++i) {
                uint32 currentMessageLength = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
                calldataPtr += 4;
                bytes32 hashedMessage = EfficientCall.keccak(
                    _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + currentMessageLength]
                );
                calldataPtr += currentMessageLength;
                reconstructedChainedMessagesHash = keccak256(abi.encode(reconstructedChainedMessagesHash, hashedMessage));
            }
            if (reconstructedChainedMessagesHash != _chainedMessagesHash) {
                revert ReconstructionMismatch(PubdataField.MsgHash, _chainedMessagesHash, reconstructedChainedMessagesHash);
            }
        }

        /// Check bytecodes
        {
            uint32 numberOfBytecodes = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
            calldataPtr += 4;
            bytes32 reconstructedChainedL1BytecodesRevealDataHash;
            for (uint256 i = 0; i < numberOfBytecodes; ++i) {
                uint32 currentBytecodeLength = uint32(
                    bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4])
                );
                calldataPtr += 4;
                reconstructedChainedL1BytecodesRevealDataHash = keccak256(
                    abi.encode(
                        reconstructedChainedL1BytecodesRevealDataHash,
                        Utils.hashL2Bytecode(
                            _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + currentBytecodeLength]
                        )
                    )
                );
                calldataPtr += currentBytecodeLength;
            }
            if (reconstructedChainedL1BytecodesRevealDataHash != _chainedBytecodesHash) {
                revert ReconstructionMismatch(
                    PubdataField.Bytecode,
                    _chainedBytecodesHash,
                    reconstructedChainedL1BytecodesRevealDataHash
                );
            }
        }

        /// Check State Diffs
        /// encoding is as follows:
        /// header (1 byte version, 3 bytes total len of compressed, 1 byte enumeration index size)
        /// body (`compressedStateDiffSize` bytes, 4 bytes number of state diffs, `numberOfStateDiffs` * `STATE_DIFF_ENTRY_SIZE` bytes for the uncompressed state diffs)
        /// encoded state diffs: [20bytes address][32bytes key][32bytes derived key][8bytes enum index][32bytes initial value][32bytes final value]
        if (
            uint256(uint8(bytes1(_totalL2ToL1PubdataAndStateDiffs[calldataPtr]))) !=
            STATE_DIFF_COMPRESSION_VERSION_NUMBER
        ) {
            revert ReconstructionMismatch(
                PubdataField.StateDiffCompressionVersion,
                bytes32(STATE_DIFF_COMPRESSION_VERSION_NUMBER),
                bytes32(uint256(uint8(bytes1(_totalL2ToL1PubdataAndStateDiffs[calldataPtr]))))
            );
        }
        ++calldataPtr;

        uint24 compressedStateDiffSize = uint24(bytes3(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 3]));
        calldataPtr += 3;

        uint8 enumerationIndexSize = uint8(bytes1(_totalL2ToL1PubdataAndStateDiffs[calldataPtr]));
        ++calldataPtr;

        bytes calldata compressedStateDiffs = _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr +
            compressedStateDiffSize];
        calldataPtr += compressedStateDiffSize;

        totalL2Pubdata = _totalL2ToL1PubdataAndStateDiffs[:calldataPtr];

        uint32 numberOfStateDiffs = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        calldataPtr += 4;

        bytes calldata stateDiffs = _totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr +
            (numberOfStateDiffs * STATE_DIFF_ENTRY_SIZE)];

        uncompressedStateDiffHash = COMPRESSOR_CONTRACT.verifyCompressedStateDiffs(
            numberOfStateDiffs,
            enumerationIndexSize,
            stateDiffs,
            compressedStateDiffs
        );

        calldataPtr += numberOfStateDiffs * STATE_DIFF_ENTRY_SIZE;

        leftoverSuffix = _totalL2ToL1PubdataAndStateDiffs[calldataPtr:];
    }
}
