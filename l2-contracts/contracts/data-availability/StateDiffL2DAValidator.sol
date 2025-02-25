// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ReconstructionMismatch, PubdataField} from "./DAErrors.sol";
import {COMPRESSOR_CONTRACT, L2ContractHelper} from "../L2ContractHelper.sol";

import {EfficientCall} from "@matterlabs/zksync-contracts/l2/system-contracts/libraries/EfficientCall.sol";

/// @dev The current version of state diff compression being used.
uint256 constant STATE_DIFF_COMPRESSION_VERSION_NUMBER = 1;

uint256 constant L2_TO_L1_LOG_SERIALIZE_SIZE = 88;

/// @dev Each state diff consists of 156 bytes of actual data and 116 bytes of unused padding, needed for circuit efficiency.
uint256 constant STATE_DIFF_ENTRY_SIZE = 272;

/// A library that could be used by any L2 DA validator to produce standard state-diff-based
/// DA output.
abstract contract StateDiffL2DAValidator {
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
        virtual
        returns (bytes32 uncompressedStateDiffHash, bytes calldata totalL2Pubdata, bytes calldata leftoverSuffix)
    {
        uint256 calldataPtr = 0;

        /// Check logs
        uint32 numberOfL2ToL1Logs = uint32(bytes4(_totalL2ToL1PubdataAndStateDiffs[calldataPtr:calldataPtr + 4]));
        calldataPtr += 4 + numberOfL2ToL1Logs * L2_TO_L1_LOG_SERIALIZE_SIZE;

        /// Check messages
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

        /// Check bytecodes
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
                    L2ContractHelper.hashL2BytecodeCalldata(
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
