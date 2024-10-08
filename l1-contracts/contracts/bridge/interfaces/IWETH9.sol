// SPDX-License-Identifier: Apache-2.0
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

interface IWETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
