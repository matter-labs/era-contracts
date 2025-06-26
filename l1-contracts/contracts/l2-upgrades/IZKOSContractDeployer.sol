// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice Interface for contract deployer system hook on ZKsyncOS.
/// @dev Note, that the actual implementation of this interface is implemented in Rust
/// as a system hook.
interface IZKOSContractDeployer {
    function setBytecodeDetailsEVM(address _addr, bytes32 _bytecodeHash, uint32 _bytecodeLength, bytes32 _observableBytecodeHash) external;
}
