// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IGenesisUpgrade {
    function upgrade(uint256 _chainId) external payable;
}
