// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract AlwaysZero {
    fallback() external {
        assembly {
            mstore(0,0)
            return(0,32)
        }
    }
}
