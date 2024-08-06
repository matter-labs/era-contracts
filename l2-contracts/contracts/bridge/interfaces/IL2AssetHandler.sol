// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2AssetHandler {
    event BridgeMint(
        uint256 indexed _chainId,
        bytes32 indexed _assetId,
        address indexed _sender,
        address _l2Receiver,
        uint256 _amount
    );

    event BridgeBurn(
        uint256 indexed _chainId,
        bytes32 indexed _assetId,
        address indexed l2Sender,
        address _receiver,
        uint256 _mintValue,
        uint256 _amount
    );

    function bridgeMint(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable;

    function bridgeBurn(
        uint256 _chainId,
        uint256 _mintValue,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable returns (bytes memory _l1BridgeMintData);
}
