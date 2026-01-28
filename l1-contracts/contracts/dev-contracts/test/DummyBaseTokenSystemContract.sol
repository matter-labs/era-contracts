// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title DummyL2BaseTokenSystemContract
/// @notice A test smart contract that simulates L2BaseToken for testing interop flows
contract DummyL2BaseTokenSystemContract {
    /// @notice The balances of the users.
    mapping(address account => uint256 balance) internal _balance;

    /// @notice Emitted during token transfers
    event Transfer(address indexed from, address indexed to, uint256 value);

    function burnMsgValue() external payable returns (bytes memory) {
        // In test context, just return empty bytes like the real implementation
        return "";
    }

    /// @notice Transfer tokens from one address to another.
    /// @param _from The address to transfer the ETH from.
    /// @param _to The address to transfer the ETH to.
    /// @param _amount The amount of ETH in wei being transferred.
    function transferFromTo(address _from, address _to, uint256 _amount) external {
        // For testing, we don't enforce caller restrictions
        // Just do the transfer if there's enough balance
        uint256 fromBalance = _balance[_from];
        require(fromBalance >= _amount, "Insufficient balance");

        unchecked {
            _balance[_from] = fromBalance - _amount;
            _balance[_to] += _amount;
        }

        emit Transfer(_from, _to, _amount);
    }

    /// @notice Returns ETH balance of an account
    function balanceOf(uint256 _account) external view returns (uint256) {
        return _balance[address(uint160(_account))];
    }

    /// @notice Set balance for testing purposes
    function setBalance(address _account, uint256 _amount) external {
        _balance[_account] = _amount;
    }
}
