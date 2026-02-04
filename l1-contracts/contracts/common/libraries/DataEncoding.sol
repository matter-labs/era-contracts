// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../l2-helpers/L2ContractAddresses.sol";
import {LEGACY_ENCODING_VERSION, NEW_ENCODING_VERSION} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IL1ERC20Bridge} from "../../bridge/interfaces/IL1ERC20Bridge.sol";
import {IAssetRouterShared} from "../../bridge/asset-router/IAssetRouterShared.sol";
import {AssetIdMismatch, IncorrectTokenAddressFromNTV, InvalidNTVBurnData, L2WithdrawalMessageWrongLength, UnsupportedEncodingVersion, BadTransferDataLength} from "../L1ContractErrors.sol";
import {WrongMsgLength} from "../../bridge/L1BridgeContractErrors.sol";
import {UnsafeBytes} from "./UnsafeBytes.sol";
import {TokenBalanceMigrationData} from "../../common/Messaging.sol";
import {INativeTokenVaultBase} from "../../bridge/ntv/INativeTokenVaultBase.sol";
import {IncorrectTokenAddressFromNTV, InvalidNTVBurnData, UnsupportedEncodingVersion, EmptyData} from "../L1ContractErrors.sol";

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

    /// @dev Encodes the transaction data hash using either the latest encoding standard or the legacy standard.
    /// @param _encodingVersion EncodingVersion.
    /// @param _originalCaller The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _nativeTokenVault The address of the token, only used if the encoding version is legacy.
    /// @param _transferData The encoded transfer data, which includes the deposit amount, the address of the L2 receiver, and potentially the token address.
    /// @return txDataHash The resulting encoded transaction data hash.
    function encodeTxDataHash(
        bytes1 _encodingVersion,
        address _originalCaller,
        bytes32 _assetId,
        address _nativeTokenVault,
        bytes memory _transferData
    ) internal view returns (bytes32 txDataHash) {
        if (_encodingVersion == LEGACY_ENCODING_VERSION) {
            address tokenAddress = INativeTokenVaultBase(_nativeTokenVault).tokenAddress(_assetId);

            // This is a double check to ensure that the used token for the legacy encoding is correct.
            // This revert should never be emitted and in real life and should only serve as a guard in
            // case of inconsistent state of Native Token Vault.
            bytes32 expectedAssetId = encodeNTVAssetId(block.chainid, tokenAddress);
            if (_assetId != expectedAssetId) {
                revert IncorrectTokenAddressFromNTV(_assetId, tokenAddress);
            }

            (uint256 depositAmount, , ) = decodeBridgeBurnData(_transferData);
            txDataHash = keccak256(abi.encode(_originalCaller, tokenAddress, depositAmount));
        } else if (_encodingVersion == NEW_ENCODING_VERSION) {
            // Similarly to calldata, the txDataHash is collision-resistant.
            // In the legacy data hash, the first encoded variable was the address, which is padded with zeros during `abi.encode`.
            txDataHash = keccak256(
                bytes.concat(_encodingVersion, abi.encode(_originalCaller, _assetId, _transferData))
            );
        } else {
            revert UnsupportedEncodingVersion();
        }
    }

    /// @notice Decodes the token data by combining chain id, asset deployment tracker and asset data.
    function decodeTokenData(
        bytes calldata _tokenData
    ) internal pure returns (uint256 chainId, bytes memory name, bytes memory symbol, bytes memory decimals) {
        if (_tokenData.length == 0) {
            revert EmptyData();
        }
        bytes1 encodingVersion = _tokenData[0];
        if (encodingVersion == LEGACY_ENCODING_VERSION) {
            (name, symbol, decimals) = abi.decode(_tokenData, (bytes, bytes, bytes));
        } else if (encodingVersion == NEW_ENCODING_VERSION) {
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

    /// @notice Encodes the asset tracker data by combining chain id, asset id, amount, minting chain status and settlement layer balance.
    /// @param _chainId The id of the chain being migrated.
    /// @param _assetId The id of the asset being migrated.
    /// @param _amount The amount being migrated.
    /// @param _migratingChainIsMinter Whether the migrating chain is a minter.
    /// @param _hasSettlingMintingChains Whether there are still settling minting chains.
    /// @param _newSLBalance The new settlement layer balance.
    /// @return The encoded asset tracker data.
    function encodeAssetTrackerData(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _migratingChainIsMinter,
        bool _hasSettlingMintingChains,
        uint256 _newSLBalance
    ) internal pure returns (bytes memory) {
        return
            abi.encode(_chainId, _assetId, _amount, _migratingChainIsMinter, _hasSettlingMintingChains, _newSLBalance);
    }

    /// @notice Decodes the asset tracker data into its component parts.
    /// @param _data The encoded asset tracker data.
    /// @return chainId The id of the chain being migrated.
    /// @return assetId The id of the asset being migrated.
    /// @return amount The amount being migrated.
    /// @return migratingChainIsMinter Whether the migrating chain is a minter.
    /// @return hasSettlingMintingChains Whether there are still settling minting chains.
    /// @return newSLBalance The new settlement layer balance.
    function decodeAssetTrackerData(
        bytes calldata _data
    )
        internal
        pure
        returns (
            uint256 chainId,
            bytes32 assetId,
            uint256 amount,
            bool migratingChainIsMinter,
            bool hasSettlingMintingChains,
            uint256 newSLBalance
        )
    {
        return abi.decode(_data, (uint256, bytes32, uint256, bool, bool, uint256));
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

    function decodeBaseTokenFinalizeWithdrawalData(
        bytes memory _l2ToL1message
    ) internal pure returns (bytes4 functionSignature, address l1Receiver, uint256 amount) {
        (uint32 functionSignatureUint, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        functionSignature = bytes4(functionSignatureUint);

        // The data is expected to be at least 56 bytes long.
        require(_l2ToL1message.length >= 56, L2WithdrawalMessageWrongLength(_l2ToL1message.length));
        // this message is a base token withdrawal
        (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        // slither-disable-next-line unused-return
        (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);
    }

    function encodeL1ERC20BridgeFinalizeWithdrawalData(
        address _l1Receiver,
        address _l1Token,
        uint256 _amount
    ) internal pure returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IL1ERC20Bridge.finalizeWithdrawal.selector, _l1Receiver, _l1Token, _amount);
    }

    function decodeLegacyFinalizeWithdrawalData(
        uint256 _l1ChainId,
        bytes memory _l2ToL1message
    ) internal pure returns (bytes4 functionSignature, address l1Token, bytes memory transferData) {
        (uint32 functionSignatureUint, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        functionSignature = bytes4(functionSignatureUint);
        // Check that the message length is correct.
        // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
        // 76 (bytes).
        require(_l2ToL1message.length == 76, L2WithdrawalMessageWrongLength(_l2ToL1message.length));
        address l1Receiver;
        uint256 amount;
        (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.
        (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        // slither-disable-next-line unused-return
        (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);

        // We also convert the data into the new format.
        transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: address(0),
            _remoteReceiver: l1Receiver,
            _originToken: l1Token,
            _amount: amount,
            _erc20Metadata: DataEncoding.encodeTokenData(_l1ChainId, bytes(""), bytes(""), bytes(""))
        });
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

    function decodeTokenBalanceMigrationData(
        bytes memory _l2ToL1message
    ) internal pure returns (bytes4 functionSignature, TokenBalanceMigrationData memory data) {
        (uint32 functionSignatureUint, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        functionSignature = bytes4(functionSignatureUint);
        bytes memory transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
        data = abi.decode(transferData, (TokenBalanceMigrationData));
    }

    function getSelector(bytes memory _data) internal pure returns (bytes4) {
        (uint32 functionSignatureUint, ) = UnsafeBytes.readUint32(_data, 0);
        return bytes4(functionSignatureUint);
    }
}
