// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IL1AssetHandler {
    event BridgeInitialize(address indexed l1Token, string name, string symbol, uint8 decimals);

    event BridgeMint(address indexed _account, uint256 _amount);

    event BridgeBurn(address indexed _account, uint256 _amount);

    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetIdentifier,
        bytes calldata _data
    ) external payable returns (address l1Receiver);

    function bridgeBurn(
        uint256 _chainId,
        uint256 _mintValue,
        bytes32 _assetIdentifier,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable returns (bytes memory _bridgeMintData);

    function bridgeClaimFailedBurn(
        uint256 _chainId,
        bytes32 _assetIdentifier,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable;
}
