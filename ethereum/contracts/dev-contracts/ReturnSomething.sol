// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract ReturnSomething {
    fallback() external payable {
        assembly {
            return(0, 0x20)
        }
    }
}
