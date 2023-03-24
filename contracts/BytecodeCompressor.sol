// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "./interfaces/IBytecodeCompressor.sol";
import "./Constants.sol";
import "./libraries/Utils.sol";
import "./libraries/UnsafeBytesCalldata.sol";

/**
 * @author Matter Labs
 * @notice Simple implementation of the compression algorithm specialized for zkEVM bytecode.
 * @dev Every deployed bytecode in zkEVM should be publicly restorable from the L1 data availability.
 * For this reason, the user may request the sequencer to publish the original bytecode and mark it as known.
 * Or the user may compress the bytecode and publish it instead (fewer data onchain!).
 */
contract BytecodeCompressor is IBytecodeCompressor {
    using UnsafeBytesCalldata for bytes;

    modifier onlyBootloader() {
        require(msg.sender == BOOTLOADER_FORMAL_ADDRESS, "Callable only by the bootloader");
        _;
    }

    /// @notice Verify the compressed bytecode and publish it on the L1.
    /// @param _bytecode The original bytecode to be verified against.
    /// @param _rawCompressedData The compressed bytecode in a format of:
    ///    - 2 bytes: the length of the dictionary
    ///    - N bytes: the dictionary
    ///    - M bytes: the encoded data
    /// @dev The dictionary is a sequence of 8-byte chunks, each of them has the associated index.
    /// @dev The encoded data is a sequence of 2-byte chunks, each of them is an index of the dictionary.
    /// @dev The compression algorithm works as follows:
    ///     1. The original bytecode is split into 8-byte chunks.
    ///     Since the bytecode size is always a multiple of 32, this is always possible.
    ///     2. For each 8-byte chunk in the original bytecode:
    ///         * If the chunk is not already in the dictionary, it is added to the dictionary array.
    ///         * If the dictionary becomes overcrowded (2^16 + 1 elements), the compression process will fail.
    ///         * The 2-byte index of the chunk in the dictionary is added to the encoded data.
    /// @dev Currently, the method may be called only from the bootloader because the server is not ready to publish bytecodes
    /// in internal transactions. However, in the future, we will allow everyone to publish compressed bytecodes.
    function publishCompressedBytecode(
        bytes calldata _bytecode,
        bytes calldata _rawCompressedData
    ) external payable onlyBootloader returns (bytes32 bytecodeHash) {
        unchecked {
            (bytes calldata dictionary, bytes calldata encodedData) = _decodeRawBytecode(_rawCompressedData);

            require(dictionary.length % 8 == 0, "Dictionary length should be a multiple of 8");
            require(dictionary.length <= 2 ** 16 * 8, "Dictionary is too big");
            require(
                encodedData.length * 4 == _bytecode.length,
                "Encoded data length should be 4 times shorter than the original bytecode"
            );

            for (uint256 encodedDataPointer = 0; encodedDataPointer < encodedData.length; encodedDataPointer += 2) {
                uint256 indexOfEncodedChunk = uint256(encodedData.readUint16(encodedDataPointer)) * 8;
                require(indexOfEncodedChunk < dictionary.length, "Encoded chunk index is out of bounds");

                uint64 encodedChunk = dictionary.readUint64(indexOfEncodedChunk);
                uint64 realChunk = _bytecode.readUint64(encodedDataPointer * 4);

                require(encodedChunk == realChunk, "Encoded chunk does not match the original bytecode");
            }
        }

        bytecodeHash = Utils.hashL2Bytecode(_bytecode);

        bytes32 rawCompressedDataHash = L1_MESSENGER_CONTRACT.sendToL1(_rawCompressedData);
        KNOWN_CODE_STORAGE_CONTRACT.markBytecodeAsPublished(
            bytecodeHash,
            rawCompressedDataHash,
            _rawCompressedData.length
        );
    }

    /// @notice Decode the raw compressed data into the dictionary and the encoded data.
    /// @param _rawCompressedData The compressed bytecode in a format of:
    ///    - 2 bytes: the bytes length of the dictionary
    ///    - N bytes: the dictionary
    ///    - M bytes: the encoded data
    function _decodeRawBytecode(
        bytes calldata _rawCompressedData
    ) internal pure returns (bytes calldata dictionary, bytes calldata encodedData) {
        unchecked {
            // The dictionary length can't be more than 2^16, so it fits into 2 bytes.
            uint256 dictionaryLen = uint256(_rawCompressedData.readUint16(0));
            dictionary = _rawCompressedData[2:2 + dictionaryLen * 8];
            encodedData = _rawCompressedData[2 + dictionaryLen * 8:];
        }
    }
}
