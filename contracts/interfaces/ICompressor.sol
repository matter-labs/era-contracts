// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

// The bitmask by applying which to the compressed state diff metadata we retrieve its operation.
uint8 constant OPERATION_BITMASK = 7;
// The number of bits shifting the compressed state diff metadata by which we retrieve its length.
uint8 constant LENGTH_BITS_OFFSET = 3;
// The maximal length in bytes that an enumeration index can have.
uint8 constant MAX_ENUMERATION_INDEX_SIZE = 8;

interface ICompressor {
    function publishCompressedBytecode(
        bytes calldata _bytecode,
        bytes calldata _rawCompressedData
    ) external payable returns (bytes32 bytecodeHash);

    function verifyCompressedStateDiffs(
        uint256 _numberOfStateDiffs,
        uint256 _enumerationIndexSize,
        bytes calldata _stateDiffs,
        bytes calldata _compressedStateDiffs
    ) external payable returns (bytes32 stateDiffHash);
}
