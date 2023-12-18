// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract Deployable {
    event Deployed(uint256 value, bytes data);

    constructor() payable {
        uint256 len;
        assembly {
            len := codesize()
        }
        bytes memory data = new bytes(len);
        assembly {
            codecopy(add(data, 0x20), 0, len)
        }
        emit Deployed(msg.value, data);
    }
}
