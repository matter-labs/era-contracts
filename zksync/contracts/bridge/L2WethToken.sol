// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IL2WethToken } from "./interfaces/IL2WethToken.sol";

contract L2WethToken is IL2WethToken {

    string public name;
    string public symbol;
    uint8 public decimals;
    
    constructor() {
        name = "Wrapped Ether";
        symbol = "WETH";
        decimals = 18;
    }

    mapping(address => uint) public override balanceOf;
    mapping(address => mapping(address => uint)) public override allowance;

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint value) external override {
        balanceOf[msg.sender] -= value;
        (bool success, ) = msg.sender.call{value: value}("");
        if (!success) {
            revert WETH_ETHTransferFailed();
        }
        emit Withdrawal(msg.sender, value);
    }

    function totalSupply() external view override returns (uint) {
        return address(this).balance;
    }

    function approve(
        address spender,
        uint value
    ) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(
        address to,
        uint value
    ) external override ensuresRecipient(to) returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;

        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint value
    ) external override ensuresRecipient(to) returns (bool) {
        if (from != msg.sender) {
            uint _allowance = allowance[from][msg.sender];
            if (_allowance != type(uint).max) {
                allowance[from][msg.sender] -= value;
            }
        }

        balanceOf[from] -= value;
        balanceOf[to] += value;

        emit Transfer(from, to, value);
        return true;
    }

    modifier ensuresRecipient(address to) {
        // Prevents from burning or sending WETH tokens to the contract.
        if (to == address(0)) {
            revert WETH_InvalidTransferRecipient();
        }
        if (to == address(this)) {
            revert WETH_InvalidTransferRecipient();
        }
        _;
    }
}
