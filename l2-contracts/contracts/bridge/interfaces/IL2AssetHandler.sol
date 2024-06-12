// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IL2AssetHandler {
    // event BridgeInitialize(address indexed l1Token, string name, string symbol, uint8 decimals);

    // event BridgeMint(address indexed _account, uint256 _amount);

    event BridgeBurn(
        uint256 indexed _chainId,
        bytes32 indexed _assetIdentifier,
        address indexed l2Sender,
        address _receiver,
        uint256 _mintValue,
        uint256 _amount
    );

    function bridgeMint(uint256 _chainId, bytes32 _assetIdentifier, bytes calldata _data) external payable;

    function bridgeBurn(
        uint256 _chainId,
        uint256 _mintValue,
        bytes32 _assetIdentifier,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable returns (bytes memory _bridgeMintData);
}
