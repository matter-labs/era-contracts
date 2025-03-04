// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {UnsafeBytes} from "../../common/libraries/UnsafeBytes.sol";

contract UnsafeBytesTest {
    // add this to be excluded from coverage report
    function test() internal virtual {}

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
