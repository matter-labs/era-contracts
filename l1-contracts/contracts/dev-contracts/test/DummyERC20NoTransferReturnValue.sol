// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract DummyERC20NoTransferReturnValue {
    function transfer(address recipient, uint256 amount) external {}
}
