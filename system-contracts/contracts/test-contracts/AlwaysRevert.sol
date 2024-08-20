// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

contract AlwaysRevert {
    fallback() external {
        revert("");
    }
}
