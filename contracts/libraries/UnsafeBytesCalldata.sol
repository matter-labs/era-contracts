// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

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
