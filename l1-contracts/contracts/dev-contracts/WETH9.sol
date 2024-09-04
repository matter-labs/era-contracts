// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.24;

import {Weth9WithdrawMoreThenBalance, Weth9WithdrawMoreThenAllowance} from "./L1DevContractsErrors.sol";

contract WETH9 {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        if (balanceOf[msg.sender] < wad) {
            revert Weth9WithdrawMoreThenBalance();
        }
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        if (balanceOf[src] < wad) {
            revert Weth9WithdrawMoreThenBalance();
        }
        if (src != msg.sender || allowance[src][msg.sender] != type(uint256).max) {
            if (allowance[src][msg.sender] < wad) {
                revert Weth9WithdrawMoreThenAllowance();
            }
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }
}
