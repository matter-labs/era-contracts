// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract Forwarder {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function forward(address to, bytes calldata data) external payable returns (bytes memory returnValue) {
        bool success;
        (success, returnValue) = payable(to).call{value: msg.value}(data);
        require(success);
    }
}
