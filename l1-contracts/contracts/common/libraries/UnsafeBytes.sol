// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @dev The library provides a set of functions that help read data from an "abi.encodePacked" byte array.
 * @dev Each of the functions accepts the `bytes memory` and the offset where data should be read and returns a value of a certain type.
 *
 * @dev WARNING!
 * 1) Functions don't check the length of the bytes array, so it can go out of bounds.
 * The user of the library must check for bytes length before using any functions from the library!
 *
 * 2) Read variables are not cleaned up - https://docs.soliditylang.org/en/v0.8.16/internals/variable_cleanup.html.
 * Using data in inline assembly can lead to unexpected behavior!
 */
library UnsafeBytes {
    /// @dev Local helper to copy `len` bytes from `src` at `srcOffset` into `dest` at `destOffset`.
    /// Correct for non-overlapping regions and handles the tail without over-write.
    function copy(bytes memory dest, uint256 destOffset, bytes memory src, uint256 srcOffset, uint256 len) internal pure {
        if (len == 0) return;
        assembly {
            let dstPtr := add(add(dest, 0x20), destOffset)
            let srcPtr := add(add(src, 0x20), srcOffset)

            let chunks := and(len, not(31))
            for { let i := 0 } lt(i, chunks) { i := add(i, 0x20) } {
                mstore(add(dstPtr, i), mload(add(srcPtr, i)))
            }

            // tail
            let rem := and(len, 31)
            if rem {
                let tailDst := add(dstPtr, chunks)
                let tailSrc := add(srcPtr, chunks)

                let remBits := shl(3, rem)
                let keepMask := shr(remBits, not(0))
                let keep := and(mload(tailDst), keepMask)
                let put := and(mload(tailSrc), not(keepMask))
                mstore(tailDst, or(put, keep))
            }
        }
    }
    function readUint32(bytes memory _bytes, uint256 _start) internal pure returns (uint32 result, uint256 offset) {
        assembly {
            offset := add(_start, 4)
            result := mload(add(_bytes, offset))
        }
    }

    function readAddress(bytes memory _bytes, uint256 _start) internal pure returns (address result, uint256 offset) {
        assembly {
            offset := add(_start, 20)
            result := mload(add(_bytes, offset))
        }
    }

    function readUint256(bytes memory _bytes, uint256 _start) internal pure returns (uint256 result, uint256 offset) {
        assembly {
            offset := add(_start, 32)
            result := mload(add(_bytes, offset))
        }
    }

    function readBytes32(bytes memory _bytes, uint256 _start) internal pure returns (bytes32 result, uint256 offset) {
        assembly {
            offset := add(_start, 32)
            result := mload(add(_bytes, offset))
        }
    }

    function readRemainingBytes(bytes memory _bytes, uint256 _start) internal pure returns (bytes memory result) {
        uint256 arrayLen = _bytes.length - _start;
        result = new bytes(arrayLen);
        copy(result, 0, _bytes, _start, arrayLen);
    }
}
