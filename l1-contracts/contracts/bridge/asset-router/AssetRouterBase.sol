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
import {L2_ASSET_ROUTER_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {IInteropCenter} from "../../interop/IInteropCenter.sol";
import {AssetHandlerDoesNotExist, AssetIdNotSupported, BadTransferDataLength, Unauthorized, UnsupportedEncodingVersion} from "../../common/L1ContractErrors.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
abstract contract AssetRouterBase is IAssetRouterBase, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev InteropCenter smart contract that is used to used as a primary point for communication of chains connected to the interop.
    /// @dev This is not used but is present for discoverability.
    IInteropCenter public immutable override INTEROP_CENTER;

    /// @dev Chain ID of L1 for bridging reasons
    uint256 public immutable L1_CHAIN_ID;

    /// @dev Chain ID of Era for legacy reasons
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev Maps asset ID to address of corresponding asset handler.
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset.
    /// @dev P.S. this liquidity was locked directly in SharedBridge before.
    /// @dev Current AssetHandlers: NTV for tokens, Bridgehub for chains.
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    /// @dev Maps asset ID to the asset deployment tracker address.
    /// @dev Tracks the address of Deployment Tracker contract on L1, which sets Asset Handlers on L2s (ZK chain).
    /// @dev For the asset and stores respective addresses.
    /// @dev Current AssetDeploymentTrackers: NTV for tokens, CTMDeploymentTracker for chains.
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[48] private __gap;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyL2InteropCenter() {
        require(msg.sender == L2_INTEROP_CENTER_ADDR, Unauthorized(msg.sender));
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(uint256 _l1ChainId, uint256 _eraChainId, IBridgehub _bridgehub, IInteropCenter _interopCenter) {
        L1_CHAIN_ID = _l1ChainId;
        ERA_CHAIN_ID = _eraChainId;
        BRIDGE_HUB = _bridgehub;
        INTEROP_CENTER = _interopCenter;
    }

    /// @inheritdoc IAssetRouterBase
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external virtual override;

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
        emit AssetDeploymentTrackerRegistered(assetId, _assetRegistrationData, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIATE DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

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

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
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
        require(BRIDGE_HUB.baseTokenAssetId(_chainId) != assetId, AssetIdNotSupported(assetId));

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
        bytes1 _encodingVersion,
        address,
        bytes calldata _data
    ) internal virtual returns (bytes32 assetId, bytes memory transferData) {
        if (_encodingVersion == NEW_ENCODING_VERSION) {
            // For better error handling.
            require(_data.length >= 33, BadTransferDataLength());
            (assetId, transferData) = abi.decode(_data[1:], (bytes32, bytes));
        } else {
            revert UnsupportedEncodingVersion();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetRouterBase
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable virtual;

    function _finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData,
        address _nativeTokenVault
    ) internal {
        address assetHandler = assetHandlerAddress[_assetId];

        if (assetHandler != address(0)) {
            IAssetHandler(assetHandler).bridgeMint{value: msg.value}(_chainId, _assetId, _transferData);
        } else {
            _setAssetHandler(_assetId, _nativeTokenVault);
            // Native token vault may not support non-zero `msg.value`, but we still provide it here to
            // prevent the passed ETH from being stuck in the asset router and also for consistency.
            // So the decision on whether to support non-zero `msg.value` is done at the asset handler layer.
            IAssetHandler(_nativeTokenVault).bridgeMint{value: msg.value}(_chainId, _assetId, _transferData); // ToDo: Maybe it's better to receive amount and receiver here? transferData may have different encoding
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    function _setAssetHandler(bytes32 _assetId, address _assetHandlerAddress) internal {
        assetHandlerAddress[_assetId] = _assetHandlerAddress;
        emit AssetHandlerRegistered(_assetId, _assetHandlerAddress);
    }

    /// @dev send the burn message to the asset
    /// @notice Forwards the burn request for specific asset to respective asset handler.
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
        address l1AssetHandler = assetHandlerAddress[_assetId];
        if (l1AssetHandler == address(0)) {
            // As a UX feature, whenever an asset handler is not present, we always try to register asset within native token vault.
            // The Native Token Vault is trusted to revert in an asset does not belong to it.
            //
            // Note, that it may "pollute" error handling a bit: instead of getting error for asset handler not being
            // present, the user will get whatever error the native token vault will return, however, providing
            // more advanced error handling requires more extensive code and will be added in the future releases.
            INativeTokenVault(_nativeTokenVault).tryRegisterTokenFromBurnData(_transferData, _assetId);

            // We do not do any additional transformations here (like setting `assetHandler` in the mapping),
            // because we expect that all those happened inside `tryRegisterTokenFromBurnData`

            l1AssetHandler = _nativeTokenVault;
        }

        uint256 msgValue = _passValue ? msg.value : 0;
        bridgeMintCalldata = IAssetHandler(l1AssetHandler).bridgeBurn{value: msgValue}({
            _chainId: _chainId,
            _msgValue: _nextMsgValue,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _data: _transferData
        });
    }

    /// @dev The request data that is passed to the bridgehub.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The deposited asset ID.
    /// @param _bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function _requestToBridge(
        address _originalCaller,
        bytes32 _assetId,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view virtual returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = getDepositCalldata(_originalCaller, _assetId, _bridgeMintCalldata);

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: _txDataHash
        });
    }

    /// @inheritdoc IAssetRouterBase
    function getDepositCalldata(
        address,
        bytes32 _assetId,
        bytes memory _assetData
    ) public view virtual override returns (bytes memory) {
        return abi.encodeCall(IAssetRouterBase.finalizeDeposit, (block.chainid, _assetId, _assetData));
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
