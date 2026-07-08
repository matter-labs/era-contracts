// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_NATIVE_TOKEN_VAULT_ADDR, L2_ASSET_ROUTER_ADDR} from "../l2-helpers/L2ContractAddresses.sol";
import {NEW_ENCODING_VERSION} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {ETH_TOKEN_ADDRESS} from "../Config.sol";
import {IAssetRouterShared} from "../../bridge/asset-router/IAssetRouterShared.sol";
import {IERC7786Attributes} from "../../interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";
import {
    AssetIdMismatch,
    InvalidNTVBurnData,
    InvalidSelector,
    UnsupportedEncodingVersion,
    BadTransferDataLength,
    EmptyData
} from "../L1ContractErrors.sol";
import {WrongMsgLength} from "../../bridge/L1BridgeContractErrors.sol";
import {
    InteropWithdrawalNonZeroValue,
    InteropWithdrawalNotSingleCall,
    InteropWithdrawalWrongDestination,
    InteropWithdrawalWrongOrigin,
    InteropWithdrawalWrongSource,
    InteropWithdrawalWrongTarget
} from "../../bridge/L1BridgeContractErrors.sol";
import {InvalidFunctionSignature} from "../../bridge/asset-tracker/AssetTrackerErrors.sol";
import {IAssetTrackerDataEncoding} from "../../bridge/asset-tracker/IAssetTrackerDataEncoding.sol";
import {UnsafeBytes} from "./UnsafeBytes.sol";
import {
    BUNDLE_IDENTIFIER,
    BundleAttributes,
    GatewayToL1TokenBalanceMigrationData,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    L1ToGatewayTokenBalanceMigrationData,
    InteropBundle,
    InteropCall,
    InteropCallStarter
} from "../../common/Messaging.sol";

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

    /// @notice Builds the single indirect-call `InteropCallStarter` for an L2->L1 asset withdrawal.
    /// @dev This is the encode counterpart of {parseInteropWithdrawalBundle}: an L2->L1 withdrawal is a
    /// single-call interop bundle whose one call is an indirect call to the L2 AssetRouter carrying the
    /// bridgehub-deposit payload for the withdrawn asset. Callers pass the resulting array to
    /// `InteropCenter.sendBundle` (directly, or ABI-encoded for an admin L1->L2 transaction). No value
    /// rides the bundle (`indirectCall` and `interopCallValue` are both zero); the withdrawn amount is
    /// carried inside `_transferData`.
    /// @param _assetId The asset being withdrawn (ERC20 assetId, base-token assetId, or CTM assetId).
    /// @param _transferData The bridgehub-burn/transfer data for the asset.
    function encodeInteropWithdrawalCallStarters(
        bytes32 _assetId,
        bytes memory _transferData
    ) internal pure returns (InteropCallStarter[] memory callStarters) {
        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));

        callStarters = new InteropCallStarter[](1);
        callStarters[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: encodeAssetRouterBridgehubDepositData(_assetId, _transferData),
            callAttributes: callAttributes
        });
    }

    /// @notice Builds the L2->L1 withdrawal message accepted by {parseInteropWithdrawalBundle}: a
    /// `BUNDLE_IDENTIFIER`-prefixed single-call `InteropBundle` wrapping the L2-asset-router
    /// `finalizeDeposit` call for the withdrawn asset, destined for this chain.
    /// @dev Message-level encode counterpart of {parseInteropWithdrawalBundle}, used to reconstruct
    /// the message the L2 InteropCenter emits (e.g. by tests and tooling that finalize withdrawals
    /// under a mocked inclusion proof). Only the fields that {parseInteropWithdrawalBundle} validates
    /// carry meaning here; the remaining bundle fields are placeholders (the real values are assigned
    /// by the L2 InteropCenter when it emits the bundle).
    /// @param _chainId The source ZK chain ID (encoded both in the bundle and the inner call).
    /// @param _l1AssetRouter The L1 asset router that the bundle's single call targets.
    /// @param _assetId The asset being withdrawn.
    /// @param _transferData The bridge-mint/transfer data for the asset.
    function encodeInteropWithdrawalBundleMessage(
        uint256 _chainId,
        address _l1AssetRouter,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                BUNDLE_IDENTIFIER,
                encodeInteropWithdrawalBundle(_chainId, _l1AssetRouter, _assetId, _transferData)
            );
    }

    /// @notice Builds the ABI-encoded single-call `InteropBundle` for an interop-routed withdrawal, without the
    /// `BUNDLE_IDENTIFIER` prefix. This is the form consumed by `IInteropHandler.executeBundle`.
    /// @dev The `destinationBaseTokenAssetId` matches what the L2 InteropCenter sets for an L1-destined bundle
    /// (L1's ETH asset ID), which `InteropHandlerBase._validateBundleDestinationContext` checks on execution.
    /// @param _chainId The source ZK chain ID (encoded both in the bundle and the inner call).
    /// @param _l1AssetRouter The L1 asset router that the bundle's single call targets.
    /// @param _assetId The asset being withdrawn.
    /// @param _transferData The bridge-mint/transfer data for the asset.
    function encodeInteropWithdrawalBundle(
        uint256 _chainId,
        address _l1AssetRouter,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal view returns (bytes memory) {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: _l1AssetRouter,
            from: L2_ASSET_ROUTER_ADDR,
            value: 0,
            data: abi.encodeCall(IAssetRouterShared.finalizeDeposit, (_chainId, _assetId, _transferData))
        });
        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: _chainId,
            destinationChainId: block.chainid,
            destinationBaseTokenAssetId: encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS),
            interopBundleSalt: bytes32(0),
            calls: calls,
            bundleAttributes: BundleAttributes({executionAddress: hex"", unbundlerAddress: hex"", useFixedFee: false})
        });
        return abi.encode(bundle);
    }

    /// @notice Parses an interop-routed withdrawal: a single-call `InteropBundle` destined for this L1.
    /// @dev The bundle is emitted by the L2 InteropCenter (`BUNDLE_IDENTIFIER`-prefixed). It must contain
    /// exactly one call, originated by the L2 asset router (`from`) and targeting this chain's L1 asset router
    /// (`to`) via `finalizeDeposit`. The inner `finalizeDeposit` payload carries `(sourceChainId, assetId, transferData)`.
    /// @param _chainId The source ZK chain ID (must match the chainId encoded in the inner call).
    /// @param _l2ToL1message The `BUNDLE_IDENTIFIER`-prefixed `abi.encode(InteropBundle)` message.
    /// @param _l1AssetRouter The L1 asset router that the bundle's single call must target.
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize the withdrawal.
    function parseInteropWithdrawalBundle(
        uint256 _chainId,
        bytes memory _l2ToL1message,
        address _l1AssetRouter
    ) internal view returns (bytes32 assetId, bytes memory transferData) {
        // Strip the 1-byte BUNDLE_IDENTIFIER prefix; the remainder is exactly `abi.encode(InteropBundle)`.
        InteropBundle memory bundle = abi.decode(UnsafeBytes.readRemainingBytes(_l2ToL1message, 1), (InteropBundle));

        require(bundle.sourceChainId == _chainId, InteropWithdrawalWrongSource());
        require(bundle.destinationChainId == block.chainid, InteropWithdrawalWrongDestination());
        require(bundle.calls.length == 1, InteropWithdrawalNotSingleCall());

        InteropCall memory interopCall = bundle.calls[0];
        require(interopCall.to == _l1AssetRouter, InteropWithdrawalWrongTarget());
        require(interopCall.from == L2_ASSET_ROUTER_ADDR, InteropWithdrawalWrongOrigin());
        // No value can ride an L2->L1 withdrawal call: the withdrawn amount is carried inside the
        // `finalizeDeposit` transfer data, and L1 finalization never forwards value.
        require(interopCall.value == 0, InteropWithdrawalNonZeroValue(interopCall.value));

        // The inner call is `abi.encodeCall(IAssetRouterShared.finalizeDeposit, (sourceChainId, assetId, transferData))`.
        require(
            bytes4(interopCall.data) == IAssetRouterShared.finalizeDeposit.selector,
            InvalidSelector(bytes4(interopCall.data))
        );
        uint256 sourceChainId;
        (sourceChainId, assetId, transferData) = abi.decode(
            UnsafeBytes.readRemainingBytes(interopCall.data, 4),
            (uint256, bytes32, bytes)
        );
        require(sourceChainId == _chainId, InteropWithdrawalWrongSource());
    }

    function decodeL1ToGatewayTokenBalanceMigrationData(
        bytes memory _l2ToL1message
    ) internal pure returns (bytes4 functionSignature, L1ToGatewayTokenBalanceMigrationData memory data) {
        (uint32 functionSignatureUint, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        functionSignature = bytes4(functionSignatureUint);
        require(
            functionSignature == IAssetTrackerDataEncoding.receiveL1ToGatewayMigrationOnL1.selector,
            InvalidFunctionSignature(functionSignature)
        );
        bytes memory transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
        data = abi.decode(transferData, (L1ToGatewayTokenBalanceMigrationData));
    }

    function decodeGatewayToL1TokenBalanceMigrationData(
        bytes memory _l2ToL1message
    ) internal pure returns (bytes4 functionSignature, GatewayToL1TokenBalanceMigrationData memory data) {
        (uint32 functionSignatureUint, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        functionSignature = bytes4(functionSignatureUint);
        require(
            functionSignature == IAssetTrackerDataEncoding.receiveGatewayToL1MigrationOnL1.selector,
            InvalidFunctionSignature(functionSignature)
        );
        bytes memory transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
        data = abi.decode(transferData, (GatewayToL1TokenBalanceMigrationData));
    }

    function getSelector(bytes memory _data) internal pure returns (bytes4) {
        (uint32 functionSignatureUint, ) = UnsafeBytes.readUint32(_data, 0);
        return bytes4(functionSignatureUint);
    }
}
