// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice Interface for contract deployer system hook on ZKsyncOS.
/// @dev Note, that the actual implementation of this interface is implemented in Rust
/// as a system hook.
interface IZKOSContractDeployer {
    function setDeployedCodeEVM(address _addr, bytes calldata _bytecode) external;
}
