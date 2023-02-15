// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @author Matter Labs
/// @dev The library with which it is possible to use `abi.decode` with error handling.
/// @dev All functions in this library are public and should be called in a try-catch block to handle errors.
library ExternalDecoder {
    /// @dev External function to decode a string from bytes.
    function decodeString(bytes memory _input) external pure returns (string memory result) {
        (result) = abi.decode(_input, (string));
    }

    /// @dev External function to decode a uint8 from bytes.
    function decodeUint8(bytes memory _input) external pure returns (uint8 result) {
        (result) = abi.decode(_input, (uint8));
    }
}
