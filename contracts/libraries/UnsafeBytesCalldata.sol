// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

/**
 * @author Matter Labs
 * @dev The library provides a set of functions that help read data from calldata bytes.
 * @dev Each of the functions accepts the `bytes calldata` and the offset where data should be read and returns a value of a certain type.
 *
 * @dev WARNING!
 * 1) Functions don't check the length of the bytes array, so it can go out of bounds.
 * The user of the library must check for bytes length before using any functions from the library!
 *
 * 2) Read variables are not cleaned up - https://docs.soliditylang.org/en/v0.8.16/internals/variable_cleanup.html.
 * Using data in inline assembly can lead to unexpected behavior!
 */
library UnsafeBytesCalldata {
    function readUint16(bytes calldata _bytes, uint256 _start) internal pure returns (uint16 result) {
        assembly {
            let offset := sub(_bytes.offset, 30)
            result := calldataload(add(offset, _start))
        }
    }

    function readUint64(bytes calldata _bytes, uint256 _start) internal pure returns (uint64 result) {
        assembly {
            let offset := sub(_bytes.offset, 24)
            result := calldataload(add(offset, _start))
        }
    }
}
