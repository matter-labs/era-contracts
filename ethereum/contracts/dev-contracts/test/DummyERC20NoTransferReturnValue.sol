// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

contract DummyERC20NoTransferReturnValue {
    function transfer(address recipient, uint256 amount) external {}
}
