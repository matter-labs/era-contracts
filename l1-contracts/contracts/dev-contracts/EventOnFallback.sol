// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract EventOnFallback {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    event Called(address msgSender, uint256 value, bytes data);

    fallback() external payable {
        emit Called(msg.sender, msg.value, msg.data);
    }
}
