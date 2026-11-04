// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title DummyBaseTokenSystemContract
/// @notice A test smart contract that simulates L2BaseToken for testing interop flows (native ETH transfers)
contract DummyBaseTokenSystemContract {
    /// @notice Emitted during token transfers
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Returns ETH balance of an account (uses native balance)
    function balanceOf(uint256 _account) external view returns (uint256) {
        return address(uint160(_account)).balance;
    }

    /// @notice Transfer tokens from one address to another.
    /// @dev In the zkfoundry VM, the bootloader calls this for ETH refunds.
    /// @dev This is a no-op since zkfoundry manages native balances directly.
    function transferFromTo(address _from, address _to, uint256 _amount) external {
        emit Transfer(_from, _to, _amount);
    }

    /// @notice Fallback to accept ETH
    receive() external payable {}
}
