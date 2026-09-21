// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockSystemContext
/// @notice A minimal mock for the SystemContext system contract on Anvil (EVM) chains.
/// @dev Supports setChainId (called during L2GenesisUpgrade) and chainId getter.
contract MockSystemContext {
    uint256 public chainId;

    /// @notice Set the chain ID. Called by L2GenesisUpgrade during genesis.
    function setChainId(uint256 _newChainId) external {
        chainId = _newChainId;
    }
}
