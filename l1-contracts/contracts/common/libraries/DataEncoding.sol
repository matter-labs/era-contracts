// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_NATIVE_TOKEN_VAULT_ADDR, L2_ASSET_ROUTER_ADDR} from "../l2-helpers/L2ContractAddresses.sol";
import {NEW_ENCODING_VERSION} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IAssetRouterShared} from "../../bridge/asset-router/IAssetRouterShared.sol";
import {IERC7786Attributes} from "../../interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";
import {
    AssetIdMismatch,
    InvalidNTVBurnData,
    UnsupportedEncodingVersion,
    BadTransferDataLength,
    EmptyData
} from "../L1ContractErrors.sol";
import {WrongMsgLength} from "../../bridge/L1BridgeContractErrors.sol";
import {UnsafeBytes} from "./UnsafeBytes.sol";
import {InteropCallStarter} from "../../common/Messaging.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for transfer data encoding and decoding to reduce possibility of errors.
 */
library DataEncoding {
    /// @notice Abi.encodes the data required for bridgeBurn for NativeTokenVault.
    /// @param _amount The amount of token to be transferred.
    /// @param _remoteReceiver The address which to receive tokens on remote chain.
    /// @param _maybeTokenAddress The helper field that should be either equal to 0 (in this case
    /// it is assumed that the token has been registered within NativeTokenVault already) or it
    /// can be equal to the address of the token on the current chain. Providing non-zero address
    /// allows it to be automatically registered in case it is not yet a part of NativeTokenVault.
    /// @return The encoded bridgeBurn data
    function encodeBridgeBurnData(
        uint256 _amount,
        address _remoteReceiver,
        address _maybeTokenAddress
    ) internal pure returns (bytes memory) {
        return abi.encode(_amount, _remoteReceiver, _maybeTokenAddress);
    }

    /// @notice Function decoding bridgeBurn data previously encoded with this library.
    /// @param _data The encoded data for bridgeBurn
    /// @return amount The amount of token to be transferred.
    /// @return receiver The address which to receive tokens on remote chain.
    /// @return maybeTokenAddress The helper field that should be either equal to 0 (in this case
    /// it is assumed that the token has been registered within NativeTokenVault already) or it
    /// can be equal to the address of the token on the current chain. Providing non-zero address
    /// allows it to be automatically registered in case it is not yet a part of NativeTokenVault.
    function decodeBridgeBurnData(
        bytes memory _data
    ) internal pure returns (uint256 amount, address receiver, address maybeTokenAddress) {
        if (_data.length != 96) {
            // For better error handling
            revert InvalidNTVBurnData();
        }

        (amount, receiver, maybeTokenAddress) = abi.decode(_data, (uint256, address, address));
    }

    function encodeAssetRouterBridgehubDepositData(
        bytes32 _assetId,
        bytes memory _transferData
    ) internal pure returns (bytes memory) {
        return bytes.concat(NEW_ENCODING_VERSION, abi.encode(_assetId, _transferData));
    }

    function decodeAssetRouterBridgehubDepositData(
        bytes calldata _dataWithVersion
    ) internal pure returns (bytes32 assetId, bytes memory transferData) {
        require(_dataWithVersion.length >= 33, BadTransferDataLength());
        require(_dataWithVersion[0] == NEW_ENCODING_VERSION, UnsupportedEncodingVersion());
        (assetId, transferData) = abi.decode(_dataWithVersion[1:], (bytes32, bytes));
    }

    /// @notice Abi.encodes the data required for bridgeMint on remote chain.
    /// @param _originalCaller The address which initiated the transfer.
    /// @param _remoteReceiver The address which to receive tokens on remote chain.
    /// @param _originToken The transferred token address.
    /// @param _amount The amount of token to be transferred.
    /// @param _erc20Metadata The transferred token metadata.
    /// @return The encoded bridgeMint data
    function encodeBridgeMintData(
        address _originalCaller,
        address _remoteReceiver,
        address _originToken,
        uint256 _amount,
        bytes memory _erc20Metadata
    ) internal pure returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return abi.encode(_originalCaller, _remoteReceiver, _originToken, _amount, _erc20Metadata);
    }

    /// @notice Function decoding transfer data previously encoded with this library.
    /// @param _bridgeMintData The encoded bridgeMint data
    /// @return _originalCaller The address which initiated the transfer.
    /// @return _remoteReceiver The address which to receive tokens on remote chain.
    /// @return _parsedOriginToken The transferred token address.
    /// @return _amount The amount of token to be transferred.
    /// @return _erc20Metadata The transferred token metadata.
    function decodeBridgeMintData(
        bytes memory _bridgeMintData
    )
        internal
        pure
        returns (
            address _originalCaller,
            address _remoteReceiver,
            address _parsedOriginToken,
            uint256 _amount,
            bytes memory _erc20Metadata
        )
    {
        (_originalCaller, _remoteReceiver, _parsedOriginToken, _amount, _erc20Metadata) = abi.decode(
            _bridgeMintData,
            (address, address, address, uint256, bytes)
        );
    }

    /// @notice Encodes the asset data by combining chain id, asset deployment tracker and asset data.
    /// @param _chainId The id of the chain token is native to.
    /// @param _assetData The asset data that has to be encoded.
    /// @param _sender The asset deployment tracker address.
    /// @return The encoded asset data.
    function encodeAssetId(uint256 _chainId, bytes32 _assetData, address _sender) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, _sender, _assetData));
    }

    /// @notice Encodes the asset data by combining chain id, asset deployment tracker and asset data.
    /// @param _chainId The id of the chain token is native to.
    /// @param _tokenAddress The address of token that has to be encoded (asset data is the address itself).
    /// @param _sender The asset deployment tracker address.
    /// @return The encoded asset data.
    function encodeAssetId(uint256 _chainId, address _tokenAddress, address _sender) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, _sender, _tokenAddress));
    }

    /// @notice Encodes the asset data by combining chain id, NTV as asset deployment tracker and asset data.
    /// @param _chainId The id of the chain token is native to.
    /// @param _assetData The asset data that has to be encoded.
    /// @return The encoded asset data.
    function encodeNTVAssetId(uint256 _chainId, bytes32 _assetData) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, L2_NATIVE_TOKEN_VAULT_ADDR, _assetData));
    }

    /// @notice Encodes the asset data by combining chain id, NTV as asset deployment tracker and token address.
    /// @param _chainId The id of the chain token is native to.
    /// @param _tokenAddress The address of token that has to be encoded (asset data is the address itself).
    /// @return The encoded asset data.
    function encodeNTVAssetId(uint256 _chainId, address _tokenAddress) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, L2_NATIVE_TOKEN_VAULT_ADDR, _tokenAddress));
    }

    /// @dev Encodes the transaction data hash using the latest encoding standard.
    /// @param _originalCaller The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes the deposit amount, the address of the L2 receiver, and potentially the token address.
    /// @return txDataHash The resulting encoded transaction data hash.
    function encodeTxDataHash(
        address _originalCaller,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal pure returns (bytes32 txDataHash) {
        // The txDataHash is collision-resistant with the removed legacy format: the legacy hash encoded an
        // address as its first word, whose most significant bytes are always zero, so it can never collide
        // with the `NEW_ENCODING_VERSION` (0x01) prefix used here.
        txDataHash = keccak256(
            bytes.concat(NEW_ENCODING_VERSION, abi.encode(_originalCaller, _assetId, _transferData))
        );
    }

    /// @notice Decodes the token data by combining chain id, asset deployment tracker and asset data.
    function decodeTokenData(
        bytes calldata _tokenData
    ) internal pure returns (uint256 chainId, bytes memory name, bytes memory symbol, bytes memory decimals) {
        if (_tokenData.length == 0) {
            revert EmptyData();
        }
        bytes1 encodingVersion = _tokenData[0];
        if (encodingVersion == NEW_ENCODING_VERSION) {
            return abi.decode(_tokenData[1:], (uint256, bytes, bytes, bytes));
        } else {
            revert UnsupportedEncodingVersion();
        }
    }

    /// @notice Encodes the token data by combining chain id, and its metadata.
    /// @dev Note that all the metadata of the token is expected to be ABI encoded.
    /// @param _chainId The id of the chain token is native to.
    /// @param _name The name of the token.
    /// @param _symbol The symbol of the token.
    /// @param _decimals The decimals of the token.
    /// @return The encoded token data.
    function encodeTokenData(
        uint256 _chainId,
        bytes memory _name,
        bytes memory _symbol,
        bytes memory _decimals
    ) internal pure returns (bytes memory) {
        return bytes.concat(NEW_ENCODING_VERSION, abi.encode(_chainId, _name, _symbol, _decimals));
    }

    /// @notice Checks if the assetId is correct.
    /// @param _tokenOriginChainId The chain id of the token origin.
    /// @param _assetId The asset id to check.
    /// @param _originToken The origin token address.
    function assetIdCheck(uint256 _tokenOriginChainId, bytes32 _assetId, address _originToken) internal pure {
        bytes32 expectedAssetId = encodeNTVAssetId(_tokenOriginChainId, _originToken);
        if (_assetId != expectedAssetId) {
            // Make sure that a NativeTokenVault sent the message
            revert AssetIdMismatch(expectedAssetId, _assetId);
        }
    }

    function encodeAssetRouterFinalizeDepositData(
        uint256 _messageSourceChainId,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal pure returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return
            abi.encodePacked(
                IAssetRouterShared.finalizeDeposit.selector,
                _messageSourceChainId,
                _assetId,
                _transferData
            );
    }

    function decodeAssetRouterFinalizeDepositData(
        bytes memory _l2ToL1message
    )
        internal
        pure
        returns (bytes4 functionSignature, uint256 _messageSourceChainId, bytes32 assetId, bytes memory transferData)
    {
        (uint32 functionSignatureUint, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        functionSignature = bytes4(functionSignatureUint);

        // The data is expected to be at least 68 bytes long to contain assetId.
        require(_l2ToL1message.length >= 68, WrongMsgLength(68, _l2ToL1message.length));
        // slither-disable-next-line unused-return
        (_messageSourceChainId, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset); // originChainId, not used for L2->L1 txs
        (assetId, offset) = UnsafeBytes.readBytes32(_l2ToL1message, offset);
        transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
    }

    /// @notice Builds the single indirect-call `InteropCallStarter` for an L2->L1 withdrawal of a registered,
    /// NON-base-token asset (an ERC20 or the CTM/ZK asset). See {protocol-docs/interop.md}.
    /// @dev No base-token value rides the bundle (both value attributes are zero); the withdrawn amount is
    /// carried inside `_transferData`. For the chain's base token use
    /// `encodeInteropBaseTokenWithdrawalCallStarters` instead.
    /// @param _assetId The asset being withdrawn — an ERC20 assetId or the CTM/ZK assetId, NOT a base-token assetId.
    /// @param _transferData The bridgehub-burn/transfer data for the asset.
    function encodeInteropWithdrawalCallStarters(
        bytes32 _assetId,
        bytes memory _transferData
    ) internal pure returns (InteropCallStarter[] memory callStarters) {
        return _encodeInteropWithdrawalCallStarters(_assetId, _transferData, 0);
    }

    /// @notice Builds the single indirect-call `InteropCallStarter` for an L2->L1 withdrawal of the chain's
    /// BASE token. See {protocol-docs/interop.md}.
    /// @dev The withdrawn amount rides as the `indirectCall` message value, so the caller of
    /// `InteropCenter.sendBundle` MUST send `_amount` as the transaction value. `interopCallValue` stays zero
    /// (`NonZeroValueToL1NotSupported`).
    /// @param _assetId The base-token assetId of the withdrawn token.
    /// @param _transferData The bridgehub-burn/transfer data for the base token; the amount it encodes must
    /// match `_amount`.
    /// @param _amount The withdrawn base-token amount, burned from the `sendBundle` transaction value.
    function encodeInteropBaseTokenWithdrawalCallStarters(
        bytes32 _assetId,
        bytes memory _transferData,
        uint256 _amount
    ) internal pure returns (InteropCallStarter[] memory callStarters) {
        return _encodeInteropWithdrawalCallStarters(_assetId, _transferData, _amount);
    }

    /// @dev Shared builder for the two withdrawal encoders above; `_indirectCallMessageValue` is the base-token
    /// amount riding along the indirect call (zero for registered-asset withdrawals).
    function _encodeInteropWithdrawalCallStarters(
        bytes32 _assetId,
        bytes memory _transferData,
        uint256 _indirectCallMessageValue
    ) private pure returns (InteropCallStarter[] memory callStarters) {
        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (_indirectCallMessageValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));

        callStarters = new InteropCallStarter[](1);
        callStarters[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: encodeAssetRouterBridgehubDepositData(_assetId, _transferData),
            callAttributes: callAttributes
        });
    }

    function getSelector(bytes memory _data) internal pure returns (bytes4) {
        (uint32 functionSignatureUint, ) = UnsafeBytes.readUint32(_data, 0);
        return bytes4(functionSignatureUint);
    }
}
