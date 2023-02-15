// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.8.0;

/**
 * @author Matter Labs
 * @dev Common utilities used in zkSync system contracts
 */
library Utils {
    /// @dev Bit mask of bytecode hash "isConstructor" marker
    bytes32 constant IS_CONSTRUCTOR_BYTECODE_HASH_BIT_MASK =
        0x00ff000000000000000000000000000000000000000000000000000000000000;

    /// @dev Bit mask to set the "isConstructor" marker in the bytecode hash
    bytes32 constant SET_IS_CONSTRUCTOR_MARKER_BIT_MASK = 
        0x0001000000000000000000000000000000000000000000000000000000000000;

    function safeCastToU128(uint256 _x) internal pure returns (uint128) {
        require(_x <= type(uint128).max, "Overflow");

        return uint128(_x);
    }

    function safeCastToU32(uint256 _x) internal pure returns (uint32) {
        require(_x <= type(uint32).max, "Overflow");

        return uint32(_x);
    }

    function safeCastToU24(uint256 _x) internal pure returns (uint24) {
        require(_x <= type(uint24).max, "Overflow");

        return uint24(_x);
    }

    /// @return codeLength The bytecode length in bytes
    function bytecodeLenInBytes(bytes32 _bytecodeHash) internal pure returns (uint256 codeLength) {
        codeLength = bytecodeLenInWords(_bytecodeHash) << 5; // _bytecodeHash * 32
    }

    /// @return codeLengthInWords The bytecode length in machine words
    function bytecodeLenInWords(bytes32 _bytecodeHash) internal pure returns (uint256 codeLengthInWords) {
        unchecked {
            codeLengthInWords = uint256(uint8(_bytecodeHash[2])) * 256 + uint256(uint8(_bytecodeHash[3]));
        }
    }

    /// @notice Denotes whether bytecode hash corresponds to a contract that is on constructor or has already been constructed
    function isContractConsructing(bytes32 _bytecodeHash) internal pure returns (bool) {
        return _bytecodeHash[1] == 0x01;
    }

    /// @notice Sets "isConstructor" flag to TRUE for the bytecode hash
    /// @param _bytecodeHash The bytecode hash for which it is needed to set the constructing flag
    /// @return The bytecode hash with "isConstructor" flag set to TRUE
    function constructingBytecodeHash(bytes32 _bytecodeHash) internal pure returns (bytes32) {
        // Clear the "isConstructor" marker and set it to 0x01.
        return constructedBytecodeHash(_bytecodeHash) | SET_IS_CONSTRUCTOR_MARKER_BIT_MASK;
    }

    /// @notice Sets "isConstructor" flag to FALSE for the bytecode hash
    /// @param _bytecodeHash The bytecode hash for which it is needed to set the constructing flag
    /// @return The bytecode hash with "isConstructor" flag set to FALSE
    function constructedBytecodeHash(bytes32 _bytecodeHash) internal pure returns (bytes32) {
        return _bytecodeHash & ~IS_CONSTRUCTOR_BYTECODE_HASH_BIT_MASK;
    }
}
