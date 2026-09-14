// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice Interface for setting contract bytecode through the system-contract deployer.
/// @dev The underlying system hook is implemented in Rust.
interface ISystemContractDeployer {
    /// @notice Sets the bytecode details for a contract.
    /// @param _addr The address of the contract.
    /// @param _bytecodeHash The ZKsyncOS internal bytecode hash.
    /// @param _bytecodeLength The bytecode length, used for both bytecode_length and observable_bytecode_length.
    /// @param _observableBytecodeHash The observable keccak256 hash of the bytecode.
    function setBytecodeDetailsEVM(
        address _addr,
        bytes32 _bytecodeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash
    ) external;
}
