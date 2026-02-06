// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockSystemContext
/// @notice A minimal mock for testing that returns a fixed settlement layer chain ID
contract MockSystemContext {
    /// @notice Returns the current settlement layer chain ID
    /// @dev For testing, we return 11 (gateway chain ID) to simulate gateway mode
    function currentSettlementLayerChainId() external pure returns (uint256) {
        return 11;
    }
}
