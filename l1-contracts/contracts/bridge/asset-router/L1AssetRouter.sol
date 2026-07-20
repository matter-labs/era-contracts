// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1AssetRouter} from "./IL1AssetRouter.sol";
import {IL2AssetRouter} from "./IL2AssetRouter.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "./IAssetRouterBase.sol";
import {AssetRouterBase} from "./AssetRouterBase.sol";

import {IL1AssetHandler} from "../interfaces/IL1AssetHandler.sol";
import {IL1CrossChainSender} from "../interfaces/IL1CrossChainSender.sol";
import {IL1Nullifier} from "../interfaces/IL1Nullifier.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";

import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE} from "../../common/Config.sol";
import {NativeTokenVaultAlreadySet} from "../L1BridgeContractErrors.sol";
import {
    AddressAlreadySet,
    AssetDeploymentTrackerNotSet,
    NonEmptyMsgValue,
    Unauthorized,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";
import {L2_ASSET_ROUTER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

import {IL1Bridgehub} from "../../core/bridgehub/IL1Bridgehub.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {IBridgehubBase, L2TransactionRequestTwoBridgesInner} from "../../core/bridgehub/IBridgehubBase.sol";

import {IL1AssetDeploymentTracker} from "../interfaces/IL1AssetDeploymentTracker.sol";
import {TxStatus} from "../../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L1 side of asset routing for L1 <-> ZK chain bridging, supporting both ETH and ERC20
/// tokens. See {protocol-docs/bridging.md}.
/// @dev Designed for use with a proxy for upgradability.
contract L1AssetRouter is AssetRouterBase, IL1AssetRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract used for asynchronous cross-chain requests, including deposits and interop-related routing.
    IL1Bridgehub public immutable BRIDGE_HUB;

    /// @dev Chain ID of Era for legacy reasons
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev The address of the WETH token on L1.
    address public immutable L1_WETH_TOKEN;

    /// @dev The assetId of the ETH.
    bytes32 public immutable ETH_TOKEN_ASSET_ID;

    /// @dev The address of ZKsync Era diamond proxy contract.
    IZKChain public immutable ERA_DIAMOND_PROXY;

    /// @dev Address of nullifier.
    IL1Nullifier public immutable L1_NULLIFIER;

    /// @dev Address of native token vault.
    INativeTokenVaultBase public nativeTokenVault;

    /// @dev Deprecated trailing slot, retained to preserve the upgradeable storage layout.
    /// Formerly `legacyBridge` (the L1ERC20 legacy-bridge support). No longer read or written.
    // slither-disable-next-line uninitialized-state
    address private __DEPRECATED_legacyBridge;

    /// @dev Address of the L1 interop handler that finalizes L2 -> L1 withdrawals.
    address public l1InteropHandler;

    /// @notice Checks that the message sender is the nullifier.
    modifier onlyNullifier() {
        require(msg.sender == address(L1_NULLIFIER), Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks that the message sender is this contract itself.
    /// @dev `finalizeDeposit` is reached only via `receiveMessage`'s self-call, mirroring the L2 asset router.
    modifier onlySelf() {
        require(msg.sender == address(this), Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or ZKsync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        require(
            msg.sender == address(BRIDGE_HUB) || (_chainId == ERA_CHAIN_ID && msg.sender == address(ERA_DIAMOND_PROXY)),
            Unauthorized(msg.sender)
        );
        _;
    }

    /// @notice Checks that the message sender is the native token vault.
    modifier onlyNativeTokenVault() {
        require(msg.sender == address(nativeTokenVault), Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    function _bridgehub() internal view virtual override returns (IBridgehubBase) {
        return IBridgehubBase(BRIDGE_HUB);
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _l1WethToken,
        address _bridgehub,
        address _l1Nullifier,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = IL1Bridgehub(_bridgehub);
        ERA_CHAIN_ID = _eraChainId;
        L1_WETH_TOKEN = _l1WethToken;
        ERA_DIAMOND_PROXY = IZKChain(_eraDiamondProxy);
        L1_NULLIFIER = IL1Nullifier(_l1Nullifier);
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy.
    /// @dev Used for testing purposes only, as the contract has been initialized on mainnet.
    /// @param _owner The address which can change L2 token implementation and upgrade the bridge implementation.
    /// The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    /// @notice Sets the NativeTokenVault contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nativeTokenVault The address of the native token vault.
    function setNativeTokenVault(INativeTokenVaultBase _nativeTokenVault) external onlyOwner {
        require(address(nativeTokenVault) == address(0), NativeTokenVaultAlreadySet());
        require(address(_nativeTokenVault) != address(0), ZeroAddress());
        nativeTokenVault = _nativeTokenVault;
        _setAssetHandler(ETH_TOKEN_ASSET_ID, address(_nativeTokenVault));
    }

    /// @notice Sets the L1 interop handler contract address, the only caller allowed to finalize withdrawals.
    /// @dev Should be called only once by the owner.
    /// @param _l1InteropHandler The address of the L1 interop handler.
    function setL1InteropHandler(address _l1InteropHandler) external onlyOwner {
        require(l1InteropHandler == address(0), AddressAlreadySet(l1InteropHandler));
        require(_l1InteropHandler != address(0), ZeroAddress());
        l1InteropHandler = _l1InteropHandler;
    }

    /// @notice Used to set the asset deployment tracker address for given asset data.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetDeploymentTracker The whitelisted address of asset deployment tracker for provided asset.
    function setAssetDeploymentTracker(
        bytes32 _assetRegistrationData,
        address _assetDeploymentTracker
    ) external onlyOwner {
        bytes32 assetId = DataEncoding.encodeAssetId(block.chainid, _assetRegistrationData, _assetDeploymentTracker);
        assetDeploymentTracker[assetId] = _assetDeploymentTracker;
        emit AssetDeploymentTrackerSet(assetId, _assetDeploymentTracker, _assetRegistrationData);
    }

    /// @inheritdoc AssetRouterBase
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external override {
        _setAssetHandlerAddressThisChain(address(nativeTokenVault), _assetRegistrationData, _assetHandlerAddress);
    }

    /// @notice Used to set the asset handler address for a given asset ID on a remote ZK chain
    /// @param _chainId The ZK chain ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The encoding of asset ID.
    /// @param _assetHandlerAddressOnCounterpart The address of the asset handler, which will hold the token of interest.
    /// @return request The tx request sent to the Bridgehub
    function _setAssetHandlerAddressOnCounterpart(
        uint256 _chainId,
        address _originalCaller,
        bytes32 _assetId,
        address _assetHandlerAddressOnCounterpart
    ) internal view returns (L2TransactionRequestTwoBridgesInner memory request) {
        require(assetDeploymentTracker[_assetId] != address(0), AssetDeploymentTrackerNotSet(_assetId));
        IL1AssetDeploymentTracker(assetDeploymentTracker[_assetId]).bridgeCheckCounterpartAddress(
            _chainId,
            _assetId,
            _originalCaller,
            _assetHandlerAddressOnCounterpart
        );

        bytes memory l2Calldata = abi.encodeCall(
            IL2AssetRouter.setAssetHandlerAddress,
            (block.chainid, _assetId, _assetHandlerAddressOnCounterpart)
        );
        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2Calldata,
            factoryDeps: new bytes[](0),
            txDataHash: bytes32(0x00)
        });
    }

    /*//////////////////////////////////////////////////////////////
                            INITIATE DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AssetRouterBase
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) public payable virtual override onlyBridgehubOrEra(_chainId) whenNotPaused {
        _bridgehubDepositBaseToken(_chainId, _assetId, _originalCaller, _amount);
    }

    /// @inheritdoc IL1CrossChainSender
    function bridgehubDeposit(
        uint256 _chainId,
        address _originalCaller,
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
        bytes1 encodingVersion = _data[0];
        if (encodingVersion == SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION) {
            require(msg.value == 0 && _value == 0, NonEmptyMsgValue());

            (bytes32 _assetId, address _assetHandlerAddressOnCounterpart) = abi.decode(_data[1:], (bytes32, address));
            return
                _setAssetHandlerAddressOnCounterpart(
                    _chainId,
                    _originalCaller,
                    _assetId,
                    _assetHandlerAddressOnCounterpart
                );
        }
        return
            _bridgehubDeposit({
                _chainId: _chainId,
                _originalCaller: _originalCaller,
                _value: _value,
                _data: _data,
                _nativeTokenVault: address(nativeTokenVault)
            });
    }

    /// @inheritdoc IL1CrossChainSender
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyBridgehub whenNotPaused {
        L1_NULLIFIER.bridgehubConfirmL2TransactionForwarded(_chainId, _txDataHash, _txHash);
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AssetRouterBase
    /// @dev Withdrawal bundles are executed by the configured L1 interop handler.
    function _interopHandler() internal view override returns (address) {
        return l1InteropHandler;
    }

    /// @inheritdoc AssetRouterBase
    /// @dev Withdrawals arriving on L1 are emitted by the L2 asset router on the source L2 chain (never L1 itself).
    function _isValidInteropSender(
        uint256 _senderChainId,
        address _senderAddress
    ) internal view override returns (bool) {
        return _senderChainId != block.chainid && _senderAddress == L2_ASSET_ROUTER_ADDR;
    }

    /// @inheritdoc AssetRouterBase
    function finalizeDeposit(
        uint256 _sourceChainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) public payable override onlySelf nonReentrant {
        _finalizeDeposit(_sourceChainId, _assetId, _transferData, address(nativeTokenVault));
        emit DepositFinalizedAssetRouter(_sourceChainId, _assetId, _transferData);
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIRM DEPOSIT Functions
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL1AssetRouter
    function bridgeConfirmTransferResult(
        uint256 _chainId,
        TxStatus _txStatus,
        address _depositSender,
        bytes32 _assetId,
        bytes calldata _assetData
    ) external override onlyNullifier nonReentrant whenNotPaused {
        IL1AssetHandler(assetHandlerAddress[_assetId]).bridgeConfirmTransferResult({
            _chainId: _chainId,
            _txStatus: _txStatus,
            _assetId: _assetId,
            _depositSender: _depositSender,
            _data: _assetData
        });

        if (_txStatus == TxStatus.Failure) {
            emit ClaimedFailedDepositAssetRouter(_chainId, _assetId, _assetData);
        }
    }
}
