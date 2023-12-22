// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract Forwarder {
    function forward(address to, bytes calldata data) external payable returns (bytes memory returnValue) {
        bool success;
        (success, returnValue) = payable(to).call{value: msg.value}(data);
        require(success);
    }
}
