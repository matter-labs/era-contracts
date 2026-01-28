// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice Interface for contract deployer system hook on ZKsyncOS.
/// @dev Note, that the actual implementation of this interface is implemented in Rust
/// as a system hook.
interface IZKOSContractDeployer {
    /// @notice Sets the bytecode details for a contract on ZKsyncOS.
    /// @dev This function is used to set the bytecode details for a contract on ZKsyncOS,
    /// it is an alternative to the `forceDeployOnAddresses` function from Era.
    /// @param _addr The address of the contract.
    /// @param _bytecodeHash The hash of the bytecode.
    /// @param _bytecodeLength The length of the bytecode (used for both bytecode_length and observable_bytecode_length).
    /// @param _observableBytecodeHash The hash of the observable bytecode.
    function setBytecodeDetailsEVM(
        address _addr,
        bytes32 _bytecodeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash
    ) external;
}
