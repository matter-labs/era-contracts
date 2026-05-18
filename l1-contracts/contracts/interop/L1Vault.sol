// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Demo L1 deposit target. Stands in for a real DeFi protocol (AAVE, Morpho, etc.)
/// for the interop bundle's terminal call. Tracks per-caller ETH deposits.
contract L1Vault {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Deposited(address indexed account, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed account, address indexed to, uint256 amount);

    error ZeroValue();
    error InsufficientBalance(uint256 have, uint256 want);
    error TransferFailed();

    function deposit() external payable {
        if (msg.value == 0) revert ZeroValue();
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Deposited(msg.sender, msg.value, balanceOf[msg.sender]);
    }

    function withdraw(uint256 amount, address to) external {
        uint256 have = balanceOf[msg.sender];
        if (amount > have) revert InsufficientBalance(have, amount);
        balanceOf[msg.sender] = have - amount;
        totalSupply -= amount;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, to, amount);
    }

    receive() external payable {
        if (msg.value == 0) revert ZeroValue();
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Deposited(msg.sender, msg.value, balanceOf[msg.sender]);
    }
}
