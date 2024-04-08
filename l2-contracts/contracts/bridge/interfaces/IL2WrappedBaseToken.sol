// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IL2WrappedBaseToken {
    event Initialize(string name, string symbol, uint8 decimals);

    function deposit() external payable;

    function withdraw(uint256 _amount) external;

    function depositTo(address _to) external payable;

    function withdrawTo(address _to, uint256 _amount) external;
}
