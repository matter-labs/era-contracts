// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title Asset Handler contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Used for any asset handler and called by the AssetRouter
interface IAssetHandler {
    /// @dev Emitted when a token is minted
    event BridgeMint(uint256 indexed chainId, bytes32 indexed assetId, address receiver, uint256 amount);

    /// @dev Emitted when a token is burned
    event BridgeBurn(
        uint256 indexed chainId,
        bytes32 indexed assetId,
        address indexed sender,
        address receiver,
        uint256 amount
    );

    /// @param _chainId the chainId that the message is from
    /// @param _assetId the assetId of the asset being bridged
    /// @param _data the actual data specified for the function
    /// @dev Note, that while payable, this function will only receive base token on L2 chains,
    /// while L1 the provided msg.value is always 0. However, this may change in the future,
    /// so if your AssetHandler implementation relies on it, it is better to explicitly check it.
    function bridgeMint(uint256 _chainId, bytes32 _assetId, bytes calldata _data) external payable;

    /// @notice Burns bridged tokens and returns the calldata for L2 <-> L1 message.
    /// @dev In case of native token vault _data is the tuple of _depositAmount and _l2Receiver.
    /// @param _chainId the chainId that the message will be sent to
    /// @param _msgValue the msg.value of the L2 transaction. For now it is always 0.
    /// @param _assetId the assetId of the asset being bridged
    /// @param _originalCaller the original caller of the
    /// @param _data the actual data specified for the function
    /// @return _bridgeMintData The calldata used by counterpart asset handler to unlock tokens for recipient.
    function bridgeBurn(
        uint256 _chainId,
        uint256 _msgValue,
        bytes32 _assetId,
        address _originalCaller,
        bytes calldata _data
    ) external payable returns (bytes memory _bridgeMintData);
}
