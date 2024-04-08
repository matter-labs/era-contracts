// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract DummyERC20NoTransferReturnValue {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function transfer(address recipient, uint256 amount) external {}
}
