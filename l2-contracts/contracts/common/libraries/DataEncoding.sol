// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS} from "../../L2ContractHelper.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for transfer data encoding and decoding to reduce possibility of errors.
 */
library DataEncoding {
    /// @notice Abi.encodes the data required for bridgeMint on remote chain.
    /// @param _prevMsgSender The address which initiated the transfer.
    /// @param _l2Receiver The address which to receive tokens on remote chain.
    /// @param _l1Token The transferred token address.
    /// @param _amount The amount of token to be transferred.
    /// @param _erc20Metadata The transferred token metadata.
    /// @return The encoded bridgeMint data
    function encodeBridgeMintData(
        address _prevMsgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes memory _erc20Metadata
    ) internal pure returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return abi.encode(_prevMsgSender, _l2Receiver, _l1Token, _amount, _erc20Metadata);
    }

    /// @notice Function decoding transfer data previously encoded with this library.
    /// @param _bridgeMintData The encoded bridgeMint data
    /// @return _prevMsgSender The address which initiated the transfer.
    /// @return _l2Receiver The address which to receive tokens on remote chain.
    /// @return _parsedL1Token The transferred token address.
    /// @return _amount The amount of token to be transferred.
    /// @return _erc20Metadata The transferred token metadata.
    function decodeBridgeMintData(
        bytes memory _bridgeMintData
    )
        internal
        pure
        returns (
            address _prevMsgSender,
            address _l2Receiver,
            address _parsedL1Token,
            uint256 _amount,
            bytes memory _erc20Metadata
        )
    {
        (_prevMsgSender, _l2Receiver, _parsedL1Token, _amount, _erc20Metadata) = abi.decode(
            _bridgeMintData,
            (address, address, address, uint256, bytes)
        );
    }

    /// @notice Encodes the asset data by combining chain id, asset deployment tracker and asset data.
    /// @param _assetData The asset data that has to be encoded.
    /// @param _sender The asset deployment tracker address.
    /// @return The encoded asset data.
    function encodeAssetId(bytes32 _assetData, address _sender) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, _sender, _assetData));
    }

    /// @notice Encodes the asset data by combining chain id, asset deployment tracker and asset data.
    /// @param _tokenAaddress The address of token that has to be encoded (asset data is the address itself).
    /// @param _sender The asset deployment tracker address.
    /// @return The encoded asset data.
    function encodeAssetId(address _tokenAaddress, address _sender) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, _sender, _tokenAaddress));
    }

    /// @notice Encodes the asset data by combining chain id, NTV as asset deployment tracker and asset data.
    /// @param _assetData The asset data that has to be encoded.
    /// @return The encoded asset data.
    function encodeNTVAssetId(bytes32 _assetData) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, _assetData));
    }

    /// @notice Encodes the asset data by combining chain id, NTV as asset deployment tracker and asset data.
    /// @param _tokenAddress The address of token that has to be encoded (asset data is the address itself).
    /// @return The encoded asset data.
    function encodeNTVAssetId(address _tokenAddress) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, _tokenAddress));
    }
}
