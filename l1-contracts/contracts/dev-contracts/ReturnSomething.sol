// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract ReturnSomething {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    fallback() external payable {
        assembly {
            return(0, 0x20)
        }
    }
}
