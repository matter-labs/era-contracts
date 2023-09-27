// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/libraries/UnsafeBytes.sol";

contract UnsafeBytesTest {
    using UnsafeBytes for bytes;

    function readUint32(bytes memory _bytes, uint256 _start) external pure returns (uint32 readValue, uint256 offset) {
        return _bytes.readUint32(_start);
    }

    function readAddress(
        bytes memory _bytes,
        uint256 _start
    ) external pure returns (address readValue, uint256 offset) {
        return _bytes.readAddress(_start);
    }

    function readUint256(
        bytes memory _bytes,
        uint256 _start
    ) external pure returns (uint256 readValue, uint256 offset) {
        return _bytes.readUint256(_start);
    }

    function readBytes32(
        bytes memory _bytes,
        uint256 _start
    ) external pure returns (bytes32 readValue, uint256 offset) {
        return _bytes.readBytes32(_start);
    }
}
