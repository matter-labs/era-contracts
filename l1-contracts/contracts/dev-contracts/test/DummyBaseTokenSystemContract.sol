// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title DummyL2BaseTokenSystemContract
/// @notice A test smart contract that simulates L2BaseToken for testing interop flows using ZKOS logic (native ETH transfers)
contract DummyL2BaseTokenSystemContract {
    /// @notice Emitted during token transfers
    event Transfer(address indexed from, address indexed to, uint256 value);

    function burnMsgValue() external payable returns (bytes memory) {
        // In test context, just return empty bytes like the real implementation
        return "";
    }

    /// @notice Returns ETH balance of an account (uses native balance)
    function balanceOf(uint256 _account) external view returns (uint256) {
        return address(uint160(_account)).balance;
    }

    /// @notice Fallback to accept ETH
    receive() external payable {}
}
