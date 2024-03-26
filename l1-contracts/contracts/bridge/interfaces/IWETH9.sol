// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

interface IWETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
