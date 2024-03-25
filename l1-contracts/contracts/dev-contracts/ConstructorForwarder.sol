// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract ConstructorForwarder {
    constructor(address to, bytes memory data) payable {
        (bool success, ) = payable(to).call{value: msg.value}(data);
        require(success);
    }
}
