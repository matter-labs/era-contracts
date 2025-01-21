// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title L1 Asset Handler contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Used for any asset handler and called by the L1AssetRouter
interface IL1AssetHandler {
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
