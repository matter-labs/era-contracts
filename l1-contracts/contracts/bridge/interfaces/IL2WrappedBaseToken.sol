// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

interface IL2WrappedBaseToken {
    event Initialize(string name, string symbol, uint8 decimals);

    function deposit() external payable;

    function withdraw(uint256 _amount) external;

    function depositTo(address _to) external payable;

    function withdrawTo(address _to, uint256 _amount) external;
}
