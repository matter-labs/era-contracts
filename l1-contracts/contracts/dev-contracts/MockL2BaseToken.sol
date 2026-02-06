// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockL2BaseToken
/// @notice A minimal mock for L2BaseToken that returns dummy values
contract MockL2BaseToken {
    /// @notice Burns msg.value amount of ETH from the user
    function burnMsgValue() external payable {
        // In a real implementation, this would burn the ETH
        // For testing, we just accept the call
    }

    /// @notice Returns the balance of an account (always returns max for testing)
    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Returns the token name
    function name() external pure returns (string memory) {
        return "Ether";
    }

    /// @notice Returns the token symbol
    function symbol() external pure returns (string memory) {
        return "ETH";
    }

    /// @notice Returns the token decimals
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
