// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IAssetRouterBase, LEGACY_ENCODING_VERSION, NEW_ENCODING_VERSION, SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "./IAssetRouterBase.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {TWO_BRIDGES_MAGIC_VALUE} from "../../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR, L2_ASSET_ROUTER_ADDR} from "../../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {UnsupportedEncodingVersion, InvalidChainId, AssetIdNotSupported, Unauthorized, AssetHandlerDoesNotExist} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
abstract contract AssetRouterBase is IAssetRouterBase, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Base token address.
    address public immutable override BASE_TOKEN_ADDRESS;

    /// @dev Chain ID of L1 for bridging reasons
    uint256 public immutable L1_CHAIN_ID;

    /// @dev Chain ID of Era for legacy reasons
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev Address of native token vault.
    INativeTokenVault public nativeTokenVault;

    /// @dev Maps asset ID to address of corresponding asset handler.
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset.
    /// @dev P.S. this liquidity was locked directly in SharedBridge before.
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    /// @dev Maps asset ID to the asset deployment tracker address.
    /// @dev Tracks the address of Deployment Tracker contract on L1, which sets Asset Handlers on L2s (ZK chain).
    /// @dev For the asset and stores respective addresses.
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(uint256 _l1ChainId, uint256 _eraChainId, IBridgehub _bridgehub, address _baseTokenAddress) {
        L1_CHAIN_ID = _l1ChainId;
        ERA_CHAIN_ID = _eraChainId;
        BRIDGE_HUB = _bridgehub;
        BASE_TOKEN_ADDRESS = _baseTokenAddress;
    }

    /// @notice Sets the asset handler address for a specified asset ID on the chain of the asset deployment tracker.
    /// @dev The caller of this function is encoded within the `assetId`, therefore, it should be invoked by the asset deployment tracker contract.
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @dev Typically, for most tokens, ADT is the native token vault. However, custom tokens may have their own specific asset deployment trackers.
    /// @dev `setAssetHandlerAddressOnCounterpart` should be called on L1 to set asset handlers on L2 chains for a specific asset ID.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetHandlerAddress The address of the asset handler to be set for the provided asset.
    function setAssetHandlerAddressThisChain(bytes32 _assetRegistrationData, address _assetHandlerAddress) external {
        bool senderIsNTV = msg.sender == address(nativeTokenVault);
        address sender = senderIsNTV ? L2_NATIVE_TOKEN_VAULT_ADDR : msg.sender;
        bytes32 assetId = DataEncoding.encodeAssetId(block.chainid, _assetRegistrationData, sender);
        if (!senderIsNTV && msg.sender != assetDeploymentTracker[assetId]) {
            revert Unauthorized(msg.sender);
        }
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        assetDeploymentTracker[assetId] = msg.sender;
        emit AssetHandlerRegisteredInitial(assetId, _assetHandlerAddress, _assetRegistrationData, sender);
    }

    function _setAssetHandlerAddress(bytes32 _assetId, address _assetAddress) internal {
        assetHandlerAddress[_assetId] = _assetAddress;
        emit AssetHandlerRegistered(_assetId, _assetAddress);
    }

    /// @dev Used to set the asset handler address on another chain. Not needed for NTV tokens.
    /// @dev Currently only enabled on L1.
    function _setAssetHandlerAddressOnCounterpart(
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        address _assetHandlerAddressOnCounterpart
    ) internal virtual returns (L2TransactionRequestTwoBridgesInner memory request) {}

    /// @inheritdoc IAssetRouterBase
    function setAssetHandlerAddress(
        uint256 _originChainId,
        bytes32 _assetId,
        address _assetAddress
    ) external virtual override {}

    /*//////////////////////////////////////////////////////////////
                            INITIATTE DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetRouterBase
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) public payable virtual override onlyBridgehub whenNotPaused {
        _bridgehubDepositBaseToken(_chainId, _assetId, _prevMsgSender, _amount);
    }

    /// @notice Deposits the base token to the bridgehub internal. Used for access management.
    function _bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) internal {
        address assetHandler = assetHandlerAddress[_assetId];
        if (assetHandler == address(0)) {
            revert AssetHandlerDoesNotExist(_assetId);
        }

        // slither-disable-next-line unused-return
        IAssetHandler(assetHandler).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _msgValue: 0,
            _assetId: _assetId,
            _prevMsgSender: _prevMsgSender,
            _data: abi.encode(_amount, address(0))
        });

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _prevMsgSender, _assetId, _amount);
    }

    /// @inheritdoc IAssetRouterBase
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _value,
        bytes calldata _data
    )
        external
        payable
        virtual
        override
        onlyBridgehub
        whenNotPaused
        returns (L2TransactionRequestTwoBridgesInner memory request)
    {
        bytes32 assetId;
        bytes memory transferData;
        bytes1 encodingVersion = _data[0];
        // The new encoding ensures that the calldata is collision-resistant with respect to the legacy format.
        // In the legacy calldata, the first input was the address, meaning the most significant byte was always `0x00`.
        if (encodingVersion == SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION) {
            (bytes32 _assetId, address _assetHandlerAddressOnCounterpart) = abi.decode(_data[1:], (bytes32, address));
            return
                _setAssetHandlerAddressOnCounterpart(
                    _chainId,
                    _prevMsgSender,
                    _assetId,
                    _assetHandlerAddressOnCounterpart
                );
        } else if (encodingVersion == NEW_ENCODING_VERSION) {
            (assetId, transferData) = abi.decode(_data[1:], (bytes32, bytes));
            if (assetHandlerAddress[assetId] == address(nativeTokenVault)) {
                revert UnsupportedEncodingVersion();
            }
        } else if (encodingVersion == LEGACY_ENCODING_VERSION) {
            if (block.chainid != L1_CHAIN_ID) {
                /// @dev Legacy bridging is only supported for L1->L2 native token transfers.
                revert InvalidChainId();
            }
            (assetId, transferData) = _handleLegacyData(_data, _prevMsgSender);
        } else {
            revert UnsupportedEncodingVersion();
        }

        if (BRIDGE_HUB.baseTokenAssetId(_chainId) == assetId) {
            revert AssetIdNotSupported(assetId);
        }

        bytes memory bridgeMintCalldata = _burn({
            _chainId: _chainId,
            _msgValue: _value,
            _assetId: assetId,
            _prevMsgSender: _prevMsgSender,
            _transferData: transferData,
            _passValue: true
        });

        bytes32 txDataHash = _encodeTxDataHash(encodingVersion, _prevMsgSender, assetId, transferData);
        request = _requestToBridge({
            _prevMsgSender: _prevMsgSender,
            _assetId: assetId,
            _bridgeMintCalldata: bridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _prevMsgSender,
            assetId: assetId,
            bridgeMintCalldata: bridgeMintCalldata
        });
    }

    /// @inheritdoc IAssetRouterBase
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external virtual override {}

    /// @inheritdoc IAssetRouterBase
    function getDepositCalldata(
        address _sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) public view override returns (bytes memory) {
        // First branch covers the case when asset is not registered with NTV (custom asset handler)
        // Second branch handles tokens registered with NTV and uses legacy calldata encoding
        if (nativeTokenVault.tokenAddress(_assetId) == address(0)) {
            return abi.encodeCall(IL1AssetRouter.finalizeDeposit, (block.chainid, _assetId, _assetData));
        } else {
            // slither-disable-next-line unused-return
            (, address _receiver, address _parsedNativeToken, uint256 _amount, bytes memory _gettersData) = DataEncoding
                .decodeBridgeMintData(_assetData);
            return
                _getLegacyNTVCalldata({
                    _sender: _sender,
                    _receiver: _receiver,
                    _parsedNativeToken: _parsedNativeToken,
                    _amount: _amount,
                    _gettersData: _gettersData
                });
        }
    }

    function _getLegacyNTVCalldata(
        address _sender,
        address _receiver,
        address _parsedNativeToken,
        uint256 _amount,
        bytes memory _gettersData
    ) internal view virtual returns (bytes memory) {}

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev The request data that is passed to the bridgehub.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The deposited asset ID.
    /// @param _bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function _requestToBridge(
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view virtual returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = getDepositCalldata(_prevMsgSender, _assetId, _bridgeMintCalldata);

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: _txDataHash
        });
    }

    function _handleLegacyData(
        bytes calldata _data,
        address _prevMsgSender
    ) internal virtual returns (bytes32, bytes memory) {}

    /// @dev Calls the internal `_encodeTxDataHash`. Used as a wrapped for try / catch case.
    /// @param _encodingVersion The version of the encoding.
    /// @param _prevMsgSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @return txDataHash The resulting encoded transaction data hash.
    function _encodeTxDataHash(
        bytes1 _encodingVersion,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal view returns (bytes32 txDataHash) {
        return
            DataEncoding.encodeTxDataHash({
                _encodingVersion: _encodingVersion,
                _prevMsgSender: _prevMsgSender,
                _assetId: _assetId,
                _nativeTokenVault: address(nativeTokenVault),
                _transferData: _transferData
            });
    }

    /// @dev send the burn message to the asset
    /// @notice Forwards the burn request for specific asset to respective asset handler.
    /// @param _chainId The chain ID of the ZK chain to which to deposit.
    /// @param _msgValue The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _assetId The deposited asset ID.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _passValue Boolean indicating whether to pass msg.value in the call.
    /// @return bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    function _burn(
        uint256 _chainId,
        uint256 _msgValue,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes memory _transferData,
        bool _passValue
    ) internal returns (bytes memory bridgeMintCalldata) {
        address l1AssetHandler = assetHandlerAddress[_assetId];
        if (l1AssetHandler == address(0)) {
            revert AssetHandlerDoesNotExist(_assetId);
        }

        uint256 msgValue = _passValue ? msg.value : 0;
        bridgeMintCalldata = IAssetHandler(l1AssetHandler).bridgeBurn{value: msgValue}({
            _chainId: _chainId,
            _msgValue: _msgValue,
            _assetId: _assetId,
            _prevMsgSender: _prevMsgSender,
            _data: _transferData
        });
    }

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
