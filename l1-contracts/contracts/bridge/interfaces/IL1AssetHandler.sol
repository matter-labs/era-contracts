// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IL1AssetHandler {
    event BridgeInitialize(address indexed l1Token, string name, string symbol, uint8 decimals);

    event BridgeMint(address indexed _account, uint256 _amount);

    event BridgeBurn(address indexed _account, uint256 _amount);

    /// @param _chainId the chainId that the message is from
    /// @param _assetId the assetId of the asset being bridged
    /// @param _data the actual data specified for the function
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable returns (address l1Receiver);

    /// @param _chainId the chainId that the message will be sent to
    /// param mintValue the amount of base tokens to be minted on L2, will be used by Weth AssetHandler
    /// @param _assetId the assetId of the asset being bridged
    /// @param _prevMsgSender the original caller of the Bridgehub, 
    /// @param _data the actual data specified for the function
    function bridgeBurn(
        uint256 _chainId,
        uint256 _mintValue,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable returns (bytes memory _bridgeMintData);

    /// @param _chainId the chainId that the message will be sent to
    /// @param _assetId the assetId of the asset being bridged
    /// @param _prevMsgSender the original caller of the Bridgehub/// @param _data the actual data specified for the function
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable;
}
