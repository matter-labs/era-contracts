// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {BridgehubBase} from "./BridgehubBase.sol";
import {IL1Bridgehub} from "./IL1Bridgehub.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {ICTMDeploymentTracker} from "../ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "../message-root/IMessageRoot.sol";
import {SettlementLayersMustSettleOnL1} from "../../common/L1ContractErrors.sol";
import {
    ChainIdAlreadyExists,
    ChainIdMismatch,
    IncorrectBridgeHubAddress,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub is the registry of chains: it manages state transition managers, base tokens and
/// chain registrations. L1->L2 communication happens through the L1InteropCenter (via ERC-7786 `sendMessage`),
/// which uses this registry and is authorized by downstream contracts through the `interopCenter` field.
contract L1Bridgehub is BridgehubBase, IL1Bridgehub {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @dev Chain ID of L1.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice The total number of ZK chains can be created/connected to this CTM.
    /// This is a temporary security measure.
    uint256 public immutable MAX_NUMBER_OF_ZK_CHAINS;

    /// @notice The L1InteropCenter contract, the single user-facing entry point for L1->L2 messaging.
    /// @dev Downstream contracts (the asset router, the cross-chain senders and the chains' Mailboxes)
    /// authorize the L1InteropCenter by reading this field.
    address public interopCenter;

    /// @notice to avoid parity hack
    constructor(address _owner, uint256 _maxNumberOfZKChains) reentrancyGuardInitializer {
        L1_CHAIN_ID = block.chainid;
        _disableInitializers();
        MAX_NUMBER_OF_ZK_CHAINS = _maxNumberOfZKChains;

        // The asset id of ETH, registered as a supported base token asset id during initialization.
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        _transferOwnership(_owner);
        _initializeInner();
    }

    /// @notice used to initialize the contract
    /// @notice this contract is also deployed on L2 as a system contract there the owner and the related functions will not be used
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
        _initializeInner();
    }

    /// @dev Returns the asset ID of ETH token for internal use.
    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }

    /// @dev Returns the maximum number of ZK chains for internal use.
    function _maxNumberOfZKChains() internal view override returns (uint256) {
        return MAX_NUMBER_OF_ZK_CHAINS;
    }

    /// @dev Returns the L1 chain ID for internal use.
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    /// @notice Sets the whitelist status of a settlement layer.
    /// @param _settlementLayerChainId the chainId of the settlement layer
    /// @param _isWhitelisted whether the settlement layer should be whitelisted
    function setSettlementLayerStatus(uint256 _settlementLayerChainId, bool _isWhitelisted) external onlyOwner {
        if (settlementLayer[_settlementLayerChainId] != block.chainid) {
            revert SettlementLayersMustSettleOnL1();
        }
        whitelistedSettlementLayers[_settlementLayerChainId] = _isWhitelisted;
        emit SettlementLayerRegistered(_settlementLayerChainId, _isWhitelisted);
    }

    /// @notice Register new chain. New chains can be only registered on Bridgehub deployed on L1. Later they can be moved to any other layer.
    /// @notice for Eth the baseToken address is 1
    /// @param _chainId the chainId of the chain
    /// @param _chainTypeManager the state transition manager address
    /// @param _baseTokenAssetId the base token asset id of the chain
    /// @param _salt the salt for the chainId, currently not used
    /// @param _admin the admin of the chain
    /// @param _initData the fixed initialization data for the chain
    /// @param _factoryDeps the factory dependencies for the chain's deployment
    function createNewChain(
        uint256 _chainId,
        address _chainTypeManager,
        bytes32 _baseTokenAssetId,
        // solhint-disable-next-line no-unused-vars
        uint256 _salt,
        address _admin,
        bytes calldata _initData,
        bytes[] calldata _factoryDeps
    ) external onlyOwnerOrAdmin nonReentrant whenNotPaused returns (uint256 chainId) {
        _validateChainParams({_chainId: _chainId, _assetId: _baseTokenAssetId, _chainTypeManager: _chainTypeManager});

        chainTypeManager[_chainId] = _chainTypeManager;

        baseTokenAssetId[_chainId] = _baseTokenAssetId;
        settlementLayer[_chainId] = block.chainid;

        address chainAddress = IChainTypeManager(_chainTypeManager).createNewChain({
            _chainId: _chainId,
            _baseTokenAssetId: _baseTokenAssetId,
            _admin: _admin,
            _initData: _initData,
            _factoryDeps: _factoryDeps
        });
        // It is an additional protection against a malicious chain type manager
        if (chainAddress == address(0)) {
            revert ZeroAddress();
        }

        _registerNewZKChain(_chainId, chainAddress, true);
        messageRoot.addNewChain(_chainId, 0);
        messageRoot.seedGenesisRoot(_chainId);

        emit NewChain(_chainId, _chainTypeManager, _admin);
        return _chainId;
    }

    /// @notice Sets the L1InteropCenter contract, the single entry point for L1->L2 transaction requests.
    /// @param _interopCenter the address of the L1InteropCenter
    function setInteropCenter(address _interopCenter) external onlyOwnerOrUpgrader {
        if (_interopCenter == address(0)) {
            revert ZeroAddress();
        }
        interopCenter = _interopCenter;
        emit InteropCenterSet(_interopCenter);
    }

    /// @notice Sets contract addresses
    function setAddresses(
        address _assetRouter,
        ICTMDeploymentTracker _l1CtmDeployer,
        IMessageRootBase _messageRoot,
        address _chainAssetHandler,
        address _chainRegistrationSender
    ) external override onlyOwnerOrUpgrader {
        assetRouter = IAssetRouterBase(_assetRouter);
        l1CtmDeployer = _l1CtmDeployer;
        messageRoot = _messageRoot;
        chainAssetHandler = _chainAssetHandler;
        chainRegistrationSender = _chainRegistrationSender;
    }

    /// @dev Registers an already deployed chain with the bridgehub
    /// @param _chainId The chain Id of the chain
    /// @param _zkChain Address of the zkChain
    function registerAlreadyDeployedZKChain(uint256 _chainId, address _zkChain) external onlyOwner {
        if (_zkChain == address(0)) {
            revert ZeroAddress();
        }
        // slither-disable-next-line unused-return
        (bool exists, ) = zkChainMap.tryGet(_chainId);
        if (exists) {
            revert ChainIdAlreadyExists();
        }
        if (IZKChain(_zkChain).getChainId() != _chainId) {
            revert ChainIdMismatch();
        }

        address ctm = IZKChain(_zkChain).getChainTypeManager();
        address chainAdmin = IZKChain(_zkChain).getAdmin();
        bytes32 chainBaseTokenAssetId = IZKChain(_zkChain).getBaseTokenAssetId();
        address bridgeHub = IZKChain(_zkChain).getBridgehub();
        uint256 batchNumber = IZKChain(_zkChain).getTotalBatchesExecuted();

        if (bridgeHub != address(this)) {
            revert IncorrectBridgeHubAddress(bridgeHub);
        }

        _validateChainParams({_chainId: _chainId, _assetId: chainBaseTokenAssetId, _chainTypeManager: ctm});

        chainTypeManager[_chainId] = ctm;

        baseTokenAssetId[_chainId] = chainBaseTokenAssetId;
        settlementLayer[_chainId] = block.chainid;

        _registerNewZKChain(_chainId, _zkChain, true);
        messageRoot.addNewChain(_chainId, batchNumber);

        emit NewChain(_chainId, ctm, chainAdmin);
    }
}
