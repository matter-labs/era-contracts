// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for encoding and decoding ZKSync OS bytecode info that is
 * used for force deployments.
 */
library ZKSyncOSBytecodeInfo {
    /// @notice Hashes EVM bytecode using keccak256.
    /// @param _bytecode The EVM bytecode to hash.
    /// @return The keccak256 hash of the bytecode.
    function hashEVMBytecode(bytes memory _bytecode) internal pure returns (bytes32) {
        return keccak256(_bytecode);
    }

    /// @notice Hashes EVM bytecode using keccak256 (calldata version).
    /// @param _bytecode The EVM bytecode to hash.
    /// @return The keccak256 hash of the bytecode.
    function hashEVMBytecodeCalldata(bytes calldata _bytecode) internal pure returns (bytes32) {
        return keccak256(_bytecode);
    }

    /// @notice Encodes the ZKSync OS bytecode info.
    /// @param _bytecodeBlakeHash The Blake2b hash of the bytecode.
    /// @param _bytecodeLength The length of the bytecode (used for both bytecode_length and observable_bytecode_length).
    /// @param _observableBytecodeHash The observable hash of the bytecode (Keccak256).
    /// @return The encoded bytecode info.
    function encodeZKSyncOSBytecodeInfo(
        bytes32 _bytecodeBlakeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash
    ) internal pure returns (bytes memory) {
        return abi.encode(_bytecodeBlakeHash, _bytecodeLength, _observableBytecodeHash);
    }

    /// @notice Decodes the ZKSync OS bytecode info.
    /// @param _bytecodeInfo The encoded bytecode info.
    /// @return bytecodeBlakeHash The Blake2b hash of the bytecode.
    /// @return bytecodeLength The length of the bytecode.
    /// @return observableBytecodeHash The observable hash of the bytecode (Keccak256).
    function decodeZKSyncOSBytecodeInfo(
        bytes memory _bytecodeInfo
    ) internal pure returns (bytes32 bytecodeBlakeHash, uint32 bytecodeLength, bytes32 observableBytecodeHash) {
        (bytecodeBlakeHash, bytecodeLength, observableBytecodeHash) = abi.decode(
            _bytecodeInfo,
            (bytes32, uint32, bytes32)
        );
    }
}
