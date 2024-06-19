// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IL2GenesisUpgrade {
    function upgrade(uint256 _chainId) external payable;
}
