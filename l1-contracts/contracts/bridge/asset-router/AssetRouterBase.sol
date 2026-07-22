// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IAssetRouterBase, NEW_ENCODING_VERSION} from "./IAssetRouterBase.sol";
import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {TWO_BRIDGES_MAGIC_VALUE} from "../../common/Config.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

import {IBridgehubBase, L2TransactionRequestTwoBridgesInner} from "../../core/bridgehub/IBridgehubBase.sol";
import {
    AssetHandlerDoesNotExist,
    AssetIdNotSupported,
    InteropSenderChainIdMismatch,
    InvalidSelector,
    PayloadTooShort,
    Unauthorized,
    UnsupportedEncodingVersion
} from "../../common/L1ContractErrors.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {IERC7786Recipient} from "../../interop/IERC7786Recipient.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Routes asset transfers (L1 <-> ZK chain bridging and L2 <-> L2 interop) to per-asset
/// handlers. See {protocol-docs/bridging.md}.
/// @dev Designed for use with a proxy for upgradability.
abstract contract AssetRouterBase is IAssetRouterBase, IERC7786Recipient, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Maps asset ID to the asset handler where bridged funds are locked/minted for that asset.
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    /// @notice Maps asset ID to the deployment tracker allowed to set the asset's handler on remote chains.
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[48] private __gap;

    function _bridgehub() internal view virtual returns (IBridgehubBase);

    /// @notice Sets the asset handler address for a specified asset ID on this chain.
    /// @dev The caller is encoded into the asset ID, so only the NTV or the asset's registered deployment
    /// tracker may call it. See {protocol-docs/bridging.md} for the registration flows.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetHandlerAddress The address of the asset handler to be set for the provided asset.
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external virtual;

    function _setAssetHandlerAddressThisChain(
        address _nativeTokenVault,
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) internal {
        bool senderIsNTV = msg.sender == _nativeTokenVault;
        address sender = senderIsNTV ? L2_NATIVE_TOKEN_VAULT_ADDR : msg.sender;
        bytes32 assetId = DataEncoding.encodeAssetId(block.chainid, _assetRegistrationData, sender);
        require(senderIsNTV || msg.sender == assetDeploymentTracker[assetId], Unauthorized(msg.sender));
        _setAssetHandler(assetId, _assetHandlerAddress);
        assetDeploymentTracker[assetId] = msg.sender;
        emit AssetDeploymentTrackerSet(assetId, msg.sender, _assetRegistrationData);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIATE BRIDGE Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows the Bridgehub (L1) / InteropCenter (L2) to acquire the destination chain's `mintValue`.
    /// @dev Records nothing: if the L2 transaction fails, the base token is refunded to the L2
    /// `refundRecipient` rather than being claimable on L1. See {protocol-docs/bridging.md}.
    /// @param _chainId The chain ID of the ZK chain to which to deposit.
    /// @param _assetId The base token asset ID of the destination chain.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) external payable virtual;

    function _bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) internal virtual {
        address assetHandler = assetHandlerAddress[_assetId];
        require(assetHandler != address(0), AssetHandlerDoesNotExist(_assetId));

        // slither-disable-next-line unused-return
        IAssetHandler(assetHandler).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _msgValue: 0,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _data: DataEncoding.encodeBridgeBurnData(_amount, address(0), address(0))
        });

        emit BridgehubDepositBaseTokenInitiated(_chainId, _originalCaller, _assetId, _amount);
    }

    function _bridgehubDeposit(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data,
        address _nativeTokenVault
    ) internal virtual whenNotPaused returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes1 encodingVersion = _data[0];
        if (encodingVersion == NEW_ENCODING_VERSION) {
            return
                _bridgehubDepositNonBaseTokenAsset({
                    _chainId: _chainId,
                    _originalCaller: _originalCaller,
                    _value: _value,
                    _data: _data,
                    _nativeTokenVault: _nativeTokenVault
                });
        } else {
            revert UnsupportedEncodingVersion();
        }
    }

    function _bridgehubDepositNonBaseTokenAsset(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data,
        address _nativeTokenVault
    ) internal returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes1 encodingVersion = _data[0];

        (bytes32 assetId, bytes memory transferData) = _getTransferData(encodingVersion, _originalCaller, _data);
        require(_bridgehub().baseTokenAssetId(_chainId) != assetId, AssetIdNotSupported(assetId));

        bytes memory bridgeMintCalldata = _burn({
            _chainId: _chainId,
            _nextMsgValue: _value,
            _assetId: assetId,
            _originalCaller: _originalCaller,
            _transferData: transferData,
            _passValue: true,
            _nativeTokenVault: _nativeTokenVault
        });

        bytes32 txDataHash = DataEncoding.encodeTxDataHash({
            _nativeTokenVault: _nativeTokenVault,
            _encodingVersion: encodingVersion,
            _originalCaller: _originalCaller,
            _assetId: assetId,
            _transferData: transferData
        });

        request = _requestToBridge({
            _chainId: _chainId,
            _originalCaller: _originalCaller,
            _assetId: assetId,
            _bridgeMintCalldata: bridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _originalCaller,
            assetId: assetId,
            bridgeMintCalldata: bridgeMintCalldata
        });
    }

    function _getTransferData(
        bytes1 /* _encodingVersion */,
        address,
        bytes calldata _data
    ) internal virtual returns (bytes32 assetId, bytes memory transferData) {
        // slither-disable-next-line unused-return
        return DataEncoding.decodeAssetRouterBridgehubDepositData(_data);
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice The interop handler on this chain that is allowed to deliver interop calls to this router.
    /// @dev On L2 this is the `L2InteropHandler` system contract; on L1 the configured `L1InteropHandler`.
    function _interopHandler() internal view virtual returns (address);

    /// @notice Validates that the interop message sender is the asset-router counterpart on the source chain.
    /// @dev On L2, only this same router (identical address on every ZK chain) may be the sender and the source
    /// cannot be L1 (interop is only initiated on L2s). On L1, the sender must be the L2 asset router.
    function _isValidInteropSender(uint256 _senderChainId, address _senderAddress) internal view virtual returns (bool);

    /// @notice Executes a cross-chain asset-router call following the ERC-7786 standard.
    /// @dev Called by this chain's interop handler while executing an interop bundle whose call targets this
    /// router with a `finalizeDeposit` payload; the payload is re-invoked via a self-call. The sender and payload
    /// validations prevent spoofed cross-chain messages and arbitrary function calls through the interop system.
    /// @param sender ERC-7930 address of the message sender (the asset router on the source chain).
    /// @param payload Encoded `finalizeDeposit` call data.
    /// @return The `receiveMessage` selector per ERC-7786.
    function receiveMessage(
        bytes32 /* receiveId */,
        bytes calldata sender,
        bytes calldata payload
    ) external payable override returns (bytes4) {
        require(msg.sender == _interopHandler(), Unauthorized(msg.sender));

        (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);
        require(_isValidInteropSender(senderChainId, senderAddress), Unauthorized(senderAddress));

        // Only a `finalizeDeposit` call may be executed through the interop system. Its ABI layout is
        // `finalizeDeposit(uint256 _sourceChainId, bytes32 _assetId, bytes _transferData)`, so the first word
        // after the 4-byte selector is `_sourceChainId`.
        require(payload.length >= 4 + 32, PayloadTooShort());
        require(
            bytes4(payload[0:4]) == AssetRouterBase.finalizeDeposit.selector,
            InvalidSelector(bytes4(payload[0:4]))
        );

        // The proven message sender's chain id must equal the payload's `_sourceChainId`, so a payload can
        // never finalize a deposit under a chain id other than the one whose message inclusion was proven.
        // Asset accounting depends on this equality; see {protocol-docs/bridging.md}.
        uint256 payloadSourceChainId = uint256(bytes32(payload[4:36]));
        require(
            senderChainId == payloadSourceChainId,
            InteropSenderChainIdMismatch(senderChainId, payloadSourceChainId)
        );

        // slither-disable-next-line arbitrary-send-eth
        (bool success, bytes memory returnData) = address(this).call{value: msg.value}(payload);
        if (!success) {
            // Bubble up the original revert reason (e.g. `InsufficientChainBalance`) instead of masking it, so
            // callers can react to the specific error (the TBM flow retries withdrawals on `InsufficientChainBalance`).
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice Finalizes a deposit/withdrawal and releases funds via the asset handler.
    /// @param _sourceChainId The chain ID the deposit/withdrawal message originates from. Note that this is the
    /// source chain of the message, not necessarily the origin chain of the bridged token.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The data needed by the asset handler (e.g. NativeTokenVault) to finalize the transfer.
    /// @dev The single finalization entry point; cross-chain messages reach it only through the interop
    /// `receiveMessage` self-call above. Chains can be malicious, so data affecting chains other than
    /// `_sourceChainId` needs special validation. See {protocol-docs/bridging.md}.
    function finalizeDeposit(
        uint256 _sourceChainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) public payable virtual;

    function _finalizeDeposit(
        uint256 _sourceChainId,
        bytes32 _assetId,
        bytes calldata _transferData,
        address _nativeTokenVault
    ) internal {
        address assetHandler = assetHandlerAddress[_assetId];

        if (assetHandler != address(0)) {
            IAssetHandler(assetHandler).bridgeMint{value: msg.value}(_sourceChainId, _assetId, _transferData);
        } else {
            _setAssetHandler(_assetId, _nativeTokenVault);
            // `msg.value` is forwarded (even though the NTV may not support non-zero value) so ETH cannot
            // get stuck in the router; value support is decided at the asset handler layer.
            IAssetHandler(_nativeTokenVault).bridgeMint{value: msg.value}(_sourceChainId, _assetId, _transferData); // ToDo: Maybe it's better to receive amount and receiver here? transferData may have different encoding
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    function _setAssetHandler(bytes32 _assetId, address _assetHandlerAddress) internal {
        assetHandlerAddress[_assetId] = _assetHandlerAddress;
        emit AssetHandlerRegistered(_assetId, _assetHandlerAddress);
    }

    /// @notice Forwards the burn request for a specific asset to the respective asset handler.
    /// @param _chainId The chain ID of the ZK chain to which to deposit.
    /// @param _nextMsgValue The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _assetId The deposited asset ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _passValue Boolean indicating whether to pass msg.value in the call.
    /// @param _nativeTokenVault The address of the native token vault.
    /// @return bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    function _burn(
        uint256 _chainId,
        uint256 _nextMsgValue,
        bytes32 _assetId,
        address _originalCaller,
        bytes memory _transferData,
        bool _passValue,
        address _nativeTokenVault
    ) internal returns (bytes memory bridgeMintCalldata) {
        address assetHandler = assetHandlerAddress[_assetId];
        if (assetHandler == address(0)) {
            // UX feature: with no handler registered, try to register the token in the NTV on the fly.
            // The NTV is trusted to revert if the asset does not belong to it (the user then sees the
            // NTV's error rather than a "handler not present" one).
            INativeTokenVaultBase(_nativeTokenVault).tryRegisterTokenFromBurnData(_transferData, _assetId);

            // `tryRegisterTokenFromBurnData` already updates the `assetHandler` mapping, nothing else to do.
            assetHandler = _nativeTokenVault;
        }

        uint256 msgValue = _passValue ? msg.value : 0;
        bridgeMintCalldata = IAssetHandler(assetHandler).bridgeBurn{value: msgValue}({
            _chainId: _chainId,
            _msgValue: _nextMsgValue,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _data: _transferData
        });
    }

    /// @notice Builds the request data that is passed to the bridgehub.
    /// @param _chainId The chain ID of the destination ZK chain.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The deposited asset ID.
    /// @param _bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify bridge requests.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function _requestToBridge(
        uint256 _chainId,
        address _originalCaller,
        bytes32 _assetId,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view virtual returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = getDepositCalldata(_originalCaller, _assetId, _bridgeMintCalldata);

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: _l2AssetRouterAddress(_chainId),
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: _txDataHash
        });
    }

    /// @dev Returns the address of the L2 asset router on the destination chain.
    /// Overridden by private interop to return the registered remote router address.
    function _l2AssetRouterAddress(uint256 /* _destinationChainId */) internal view virtual returns (address) {
        return L2_ASSET_ROUTER_ADDR;
    }

    /// @notice Builds the `finalizeDeposit` calldata executed on the destination chain.
    function getDepositCalldata(
        address,
        bytes32 _assetId,
        bytes memory _assetData
    ) public view virtual returns (bytes memory) {
        return abi.encodeCall(AssetRouterBase.finalizeDeposit, (block.chainid, _assetId, _assetData));
    }

    /// @notice Ensures that token is registered with native token vault.
    /// @dev Only used when deposit is made with legacy data encoding format.
    /// @param _token The native token address which should be registered with native token vault.
    /// @return assetId The asset ID of the token provided.
    function _ensureTokenRegisteredWithNTV(address _token) internal virtual returns (bytes32 assetId);

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
