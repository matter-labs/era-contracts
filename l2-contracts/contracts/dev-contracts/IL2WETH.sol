pragma solidity ^0.8.0;

// SPDX-License-Identifier: MIT

interface IL2WETH {
    event Initialize(string name, string symbol, uint8 decimals);

    function deposit() external payable;

    function withdraw(uint256 _amount) external;

    function depositTo(address _to) external payable;

    function withdrawTo(address _to, uint256 _amount) external;
}
