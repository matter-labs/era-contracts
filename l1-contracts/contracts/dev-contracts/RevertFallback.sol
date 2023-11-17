// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract RevertFallback {
    fallback() external payable {
        revert();
    }
}
