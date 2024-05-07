// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract DummyERC20NoTransferReturnValue {
    function transfer(address recipient, uint256 amount) external {}
}
