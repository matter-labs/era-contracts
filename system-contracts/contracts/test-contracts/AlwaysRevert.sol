// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

contract AlwaysRevert {
    fallback() external {
        revert("");
    }
}
