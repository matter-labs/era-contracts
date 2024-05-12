// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IStandardToken {
    event BridgeInitialize(address indexed l1Token, string name, string symbol, uint8 decimals);

    event BridgeMint(address indexed _account, uint256 _amount);

    event BridgeBurn(address indexed _account, uint256 _amount);

    function bridgeMint(address _account, uint256 _amount) external payable;

    function bridgeBurn(
        uint256 _chainId,
        bytes32 _assetInfo,
        address _account,
        bytes calldata _assetData
    ) external payable returns (bytes calldata _bridgeMintCalldata);
}
