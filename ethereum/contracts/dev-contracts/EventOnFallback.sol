// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract EventOnFallback {
    event Called(address msgSender, uint256 value, bytes data);

    fallback() external payable {
        emit Called(msg.sender, msg.value, msg.data);
    }
}
