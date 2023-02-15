// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract DummyERC20NoTransferReturnValue {
    function transfer(address recipient, uint256 amount) external {}
}
