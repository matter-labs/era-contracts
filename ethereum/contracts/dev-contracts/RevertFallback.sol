// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

contract RevertFallback {
    fallback() external payable {
        revert();
    }
}
