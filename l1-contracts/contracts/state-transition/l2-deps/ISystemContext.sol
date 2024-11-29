// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

interface ISystemContext {
    /// @notice Set the chain configuration.
    /// @param _newChainId The chainId
    /// @param _newAllowedBytecodeTypes The new allowed bytecode types mode.
    function setChainConfiguration(uint256 _newChainId, uint256 _newAllowedBytecodeTypes) external;
}
