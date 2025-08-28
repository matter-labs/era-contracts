// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2AssetRouter} from "./IL2AssetRouter.sol";
import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {AssetRouterBase} from "./AssetRouterBase.sol";

import {IL2NativeTokenVault} from "../ntv/IL2NativeTokenVault.sol";
import {IL2SharedBridgeLegacy} from "../interfaces/IL2SharedBridgeLegacy.sol";
import {IBridgedStandardToken} from "../interfaces/IBridgedStandardToken.sol";
import {IL1ERC20Bridge} from "../interfaces/IL1ERC20Bridge.sol";

import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";

import {L2_NATIVE_TOKEN_VAULT_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {L2ContractHelper} from "../../common/l2-helpers/L2ContractHelper.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {AmountMustBeGreaterThanZero, AssetIdNotSupported, EmptyAddress, InvalidCaller, TokenNotLegacy} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
/// @dev Important: L2 contracts are not allowed to have any immutable variables. This is needed for compatibility with ZKsyncOS.
contract L2AssetRouter is AssetRouterBase, IL2AssetRouter, ReentrancyGuard {
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    IBridgehub public override BRIDGE_HUB;

    /// @dev Chain ID of L1 for bridging reasons.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public L1_CHAIN_ID;

    /// @dev Chain ID of Era for legacy reasons.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public eraChainId;

    /// @dev The address of the L1 asset router counterpart.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    address public L1_ASSET_ROUTER;

    /// @dev The address of the L2 legacy shared bridge.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    address public L2_LEGACY_SHARED_BRIDGE;

    /// @dev The asset id of the base token.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 public BASE_TOKEN_ASSET_ID;

    /// @notice Checks that the message sender is the L1 Asset Router.
    modifier onlyAssetRouterCounterpart(uint256 _originChainId) {
        if (_originChainId == _l1ChainId()) {
            // Only the L1 Asset Router counterpart can initiate and finalize the deposit.
            if (AddressAliasHelper.undoL1ToL2Alias(msg.sender) != L1_ASSET_ROUTER) {
                revert InvalidCaller(msg.sender);
            }
        } else {
            revert InvalidCaller(msg.sender); // xL2 messaging not supported for now
        }
        _;
    }

    /// @notice Checks that the message sender is the L1 Asset Router.
    modifier onlyAssetRouterCounterpartOrSelf(uint256 _chainId) {
        if (_chainId == _l1ChainId()) {
            // Only the L1 Asset Router counterpart can initiate and finalize the deposit.
            if ((AddressAliasHelper.undoL1ToL2Alias(msg.sender) != L1_ASSET_ROUTER) && (msg.sender != address(this))) {
                revert InvalidCaller(msg.sender);
            }
        } else {
            revert InvalidCaller(msg.sender); // xL2 messaging not supported for now
        }
        _;
    }

    /// @notice Checks that the message sender is the legacy L2 bridge.
    modifier onlyLegacyBridge() {
        if (msg.sender != L2_LEGACY_SHARED_BRIDGE) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    modifier onlyNTV() {
        if (msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @notice Initializes the contract
    /// @dev This function is used to initialize the contract with the initial values.
    /// @dev This function is called both for new chains.
    /// @param _l1ChainId The chain id of L1.
    /// @param _eraChainId The chain id of Era.
    /// @param _l1AssetRouter The address of the L1 asset router.
    /// @param _legacySharedBridge The address of the L2 legacy shared bridge.
    /// @param _baseTokenAssetId The asset id of the base token.
    /// @param _aliasedOwner The address of the owner of the contract.
    function initL2(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _l1AssetRouter,
        address _legacySharedBridge,
        bytes32 _baseTokenAssetId,
        address _aliasedOwner
    ) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();
        updateL2(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge, _baseTokenAssetId);
        _setAssetHandler(_baseTokenAssetId, L2_NATIVE_TOKEN_VAULT_ADDR);
        _transferOwnership(_aliasedOwner);
    }

    /// @notice Updates the contract.
    /// @dev This function is used to initialize the new implementation of L2AssetRouter on existing chains during
    /// the upgrade.
    /// @param _l1ChainId The chain id of L1.
    /// @param _eraChainId The chain id of Era.
    /// @param _l1AssetRouter The address of the L1 asset router.
    /// @param _legacySharedBridge The address of the L2 legacy shared bridge.
    /// @param _baseTokenAssetId The asset id of the base token.
    function updateL2(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _l1AssetRouter,
        address _legacySharedBridge,
        bytes32 _baseTokenAssetId
    ) public onlyUpgrader {
        L2_LEGACY_SHARED_BRIDGE = _legacySharedBridge;
        if (_l1AssetRouter == address(0)) {
            revert EmptyAddress();
        }
        L1_CHAIN_ID = _l1ChainId;
        L1_ASSET_ROUTER = _l1AssetRouter;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        eraChainId = _eraChainId;
    }

    /// @inheritdoc IL2AssetRouter
    function setAssetHandlerAddress(
        uint256 _originChainId,
        bytes32 _assetId,
        address _assetHandlerAddress
    ) external override onlyAssetRouterCounterpart(_originChainId) {
        _setAssetHandler(_assetId, _assetHandlerAddress);
    }

    /// @inheritdoc IAssetRouterBase
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external override(AssetRouterBase, IAssetRouterBase) {
        _setAssetHandlerAddressThisChain(L2_NATIVE_TOKEN_VAULT_ADDR, _assetRegistrationData, _assetHandlerAddress);
    }

    function setLegacyTokenAssetHandler(bytes32 _assetId) external override onlyNTV {
        // Note, that it is an asset handler, but not asset deployment tracker,
        // which is located on L1.
        _setAssetHandler(_assetId, L2_NATIVE_TOKEN_VAULT_ADDR);
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalize the deposit and mint funds
    /// @param _assetId The encoding of the asset on L2
    /// @param _transferData The encoded data required for deposit (address _l1Sender, uint256 _amount, address _l2Receiver, bytes memory erc20Data, address originToken)
    function finalizeDeposit(
        // solhint-disable-next-line no-unused-vars
        uint256,
        bytes32 _assetId,
        bytes calldata _transferData
    )
        public
        payable
        override(AssetRouterBase, IAssetRouterBase)
        onlyAssetRouterCounterpartOrSelf(_l1ChainId())
        nonReentrant
    {
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            revert AssetIdNotSupported(BASE_TOKEN_ASSET_ID);
        }
        _finalizeDeposit(_l1ChainId(), _assetId, _transferData, L2_NATIVE_TOKEN_VAULT_ADDR);

        emit DepositFinalizedAssetRouter(_l1ChainId(), _assetId, _transferData);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @dev IMPORTANT: this method will be deprecated in one of the future releases, so contracts
    /// that rely on it must be upgradeable.
    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    function withdraw(bytes32 _assetId, bytes memory _assetData) public override nonReentrant returns (bytes32) {
        return _withdrawSender(_assetId, _assetData, msg.sender, true);
    }

    /*//////////////////////////////////////////////////////////////
                     Internal & Helpers
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AssetRouterBase
    function _ensureTokenRegisteredWithNTV(address _token) internal override returns (bytes32 assetId) {
        assetId = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).ensureTokenIsRegistered(_token);
    }

    /// @param _assetId The asset id of the withdrawn asset
    /// @param _assetData The data that is passed to the asset handler contract
    /// @param _sender The address of the sender of the message
    /// @param _alwaysNewMessageFormat Whether to use the new message format compatible with Custom Asset Handlers
    function _withdrawSender(
        bytes32 _assetId,
        bytes memory _assetData,
        address _sender,
        bool _alwaysNewMessageFormat
    ) internal returns (bytes32 txHash) {
        bytes memory l1bridgeMintData = _burn({
            _chainId: _l1ChainId(),
            _nextMsgValue: 0,
            _assetId: _assetId,
            _originalCaller: _sender,
            _transferData: _assetData,
            _passValue: false,
            _nativeTokenVault: L2_NATIVE_TOKEN_VAULT_ADDR
        });

        bytes memory message;
        if (_alwaysNewMessageFormat || L2_LEGACY_SHARED_BRIDGE == address(0)) {
            message = _getAssetRouterWithdrawMessage(_assetId, l1bridgeMintData);
            // slither-disable-next-line unused-return
            txHash = L2ContractHelper.sendMessageToL1(message);
        } else {
            address l1Token = IBridgedStandardToken(
                IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).tokenAddress(_assetId)
            ).originToken();
            if (l1Token == address(0)) {
                revert AssetIdNotSupported(_assetId);
            }
            // slither-disable-next-line unused-return
            (uint256 amount, address l1Receiver, ) = DataEncoding.decodeBridgeBurnData(_assetData);
            message = _getSharedBridgeWithdrawMessage(l1Receiver, l1Token, amount);
            txHash = IL2SharedBridgeLegacy(L2_LEGACY_SHARED_BRIDGE).sendMessageToL1(message);
        }

        emit WithdrawalInitiatedAssetRouter(_l1ChainId(), _sender, _assetId, _assetData);
    }

    /// @notice Encodes the message for l2ToL1log sent during withdraw initialization.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _l1bridgeMintData The calldata used by l1 asset handler to unlock tokens for recipient.
    function _getAssetRouterWithdrawMessage(
        bytes32 _assetId,
        bytes memory _l1bridgeMintData
    ) internal view returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IAssetRouterBase.finalizeDeposit.selector, block.chainid, _assetId, _l1bridgeMintData);
    }

    /// @notice Encodes the message for l2ToL1log sent during withdraw initialization.
    function _getSharedBridgeWithdrawMessage(
        address _l1Receiver,
        address _l1Token,
        uint256 _amount
    ) internal pure returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IL1ERC20Bridge.finalizeWithdrawal.selector, _l1Receiver, _l1Token, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Legacy finalizeDeposit.
    /// @dev Finalizes the deposit and mint funds.
    /// @param _l1Sender The address of token sender on L1.
    /// @param _l2Receiver The address of token receiver on L2.
    /// @param _l1Token The address of the token transferred.
    /// @param _amount The amount of the token transferred.
    /// @param _data The metadata of the token transferred.
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external payable onlyAssetRouterCounterpart(L1_CHAIN_ID) {
        _translateLegacyFinalizeDeposit({
            _l1Sender: _l1Sender,
            _l2Receiver: _l2Receiver,
            _l1Token: _l1Token,
            _amount: _amount,
            _data: _data
        });
    }

    function finalizeDepositLegacyBridge(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external onlyLegacyBridge {
        _translateLegacyFinalizeDeposit({
            _l1Sender: _l1Sender,
            _l2Receiver: _l2Receiver,
            _l1Token: _l1Token,
            _amount: _amount,
            _data: _data
        });
    }

    function _translateLegacyFinalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) internal {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1Token);
        // solhint-disable-next-line func-named-parameters
        bytes memory data = DataEncoding.encodeBridgeMintData(_l1Sender, _l2Receiver, _l1Token, _amount, _data);
        this.finalizeDeposit{value: msg.value}(L1_CHAIN_ID, assetId, data);
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @dev A compatibility method to support legacy functionality for the SDK.
    /// @param _l1Receiver The account address that should receive funds on L1
    /// @param _l2Token The L2 token address which is withdrawn
    /// @param _amount The total amount of tokens to be withdrawn
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external nonReentrant {
        if (_amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        _withdrawLegacy(_l1Receiver, _l2Token, _amount, msg.sender);
    }

    /// @notice Legacy withdraw.
    /// @dev Finalizes the deposit and mint funds.
    /// @param _l1Receiver The address of token receiver on L1.
    /// @param _l2Token The address of token on L2.
    /// @param _amount The amount of the token transferred.
    /// @param _sender The original msg.sender.
    function withdrawLegacyBridge(
        address _l1Receiver,
        address _l2Token,
        uint256 _amount,
        address _sender
    ) external onlyLegacyBridge nonReentrant {
        _withdrawLegacy(_l1Receiver, _l2Token, _amount, _sender);
    }

    function _withdrawLegacy(address _l1Receiver, address _l2Token, uint256 _amount, address _sender) internal {
        address l1Address = l1TokenAddress(_l2Token);
        if (l1Address == address(0)) {
            revert TokenNotLegacy();
        }
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Address);
        bytes memory data = DataEncoding.encodeBridgeBurnData(_amount, _l1Receiver, _l2Token);
        _withdrawSender(assetId, data, _sender, false);
    }

    /// @notice Legacy getL1TokenAddress.
    /// @param _l2Token The address of token on L2.
    /// @return The address of token on L1.
    function l1TokenAddress(address _l2Token) public view returns (address) {
        bytes32 assetId = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).assetId(_l2Token);
        if (assetId == bytes32(0)) {
            return address(0);
        }
        uint256 originChainId = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).originChainId(assetId);
        if (originChainId != L1_CHAIN_ID) {
            return address(0);
        }

        return IBridgedStandardToken(_l2Token).originToken();
    }

    /// @notice Legacy function used for backward compatibility to return L2 wrapped token
    /// @notice address corresponding to provided L1 token address and deployed through NTV.
    /// @dev However, the shared bridge can use custom asset handlers such that L2 addresses differ,
    /// @dev or an L1 token may not have an L2 counterpart.
    /// @param _l1Token The address of token on L1.
    /// @return Address of an L2 token counterpart
    function l2TokenAddress(address _l1Token) public view returns (address) {
        IL2NativeTokenVault l2NativeTokenVault = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        address currentlyDeployedAddress = l2NativeTokenVault.l2TokenAddress(_l1Token);

        if (currentlyDeployedAddress != address(0)) {
            return currentlyDeployedAddress;
        }

        // For backwards compatibility, the bridge smust return the address of the token even if it
        // has not been deployed yet.
        return l2NativeTokenVault.calculateCreate2TokenAddress(L1_CHAIN_ID, _l1Token);
    }

    /// @notice Returns the address of the L1 asset router.
    /// @dev The old name is kept for backward compatibility.
    function l1Bridge() external view returns (address) {
        return L1_ASSET_ROUTER;
    }

    function _bridgehub() internal view override returns (IBridgehub) {
        return BRIDGE_HUB;
    }

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _eraChainId() internal view override returns (uint256) {
        return eraChainId;
    }
}
