// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title L1 Asset Handler contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Used for any asset handler and called by the L1SharedBridge
interface IL1AssetHandler {
    /// @dev Emitted when a new token is initialized
    event BridgeInitialize(address indexed l1Token, string name, string symbol, uint8 decimals);

    /// @dev Emitted when a token is minted
    event BridgeMint(uint256 indexed _chainId, bytes32 indexed _assetId, address _l1Receiver, uint256 _amount);

    /// @dev Emitted when a token is burned
    event BridgeBurn(
        uint256 indexed _chainId,
        bytes32 indexed _assetId,
        address indexed _l1Sender,
        address _l2receiver,
        uint256 _amount
    );

    /// @param _chainId the chainId that the message is from
    /// @param _assetId the assetId of the asset being bridged
    /// @param _data the actual data specified for the function
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable returns (address l1Receiver);

    /// @param _chainId the chainId that the message will be sent to
    /// @param _l2Value the msg.value of the L2 transaction
    /// @param _assetId the assetId of the asset being bridged
    /// @param _prevMsgSender the original caller of the Bridgehub,
    /// @param _data the actual data specified for the function
    function bridgeBurn(
        uint256 _chainId,
        uint256 _l2Value,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable returns (bytes memory _bridgeMintData);

    /// @param _chainId the chainId that the message will be sent to
    /// @param _assetId the assetId of the asset being bridged
    /// @param _depositSender the address of the entity that initiated the deposit.
    /// @param _data the actual data specified for the function
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable;
}
