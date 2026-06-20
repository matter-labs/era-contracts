// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

interface IBridgedStandardToken {
    event BridgeInitialize(address indexed l1Token, string name, string symbol, uint8 decimals);

    event BridgeMint(address indexed account, uint256 amount);

    event BridgeBurn(address indexed account, uint256 amount);

    function bridgeMint(address _account, uint256 _amount) external;

    function bridgeBurn(address _account, uint256 _amount) external;

    function l1Address() external view returns (address);

    function originToken() external view returns (address);

    function l2Bridge() external view returns (address);

    function assetId() external view returns (bytes32);

    function nativeTokenVault() external view returns (address);
}
