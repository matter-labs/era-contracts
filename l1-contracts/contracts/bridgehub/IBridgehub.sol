// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1AssetRouter} from "../bridge/interfaces/IL1AssetRouter.sol";
import {L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {IL1AssetHandler} from "../bridge/interfaces/IL1AssetHandler.sol";
import {ISTMDeploymentTracker} from "./ISTMDeploymentTracker.sol";
import {IMessageRoot} from "./IMessageRoot.sol";

struct L2TransactionRequestDirect {
    uint256 chainId;
    uint256 mintValue;
    address l2Contract;
    uint256 l2Value;
    bytes l2Calldata;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    bytes[] factoryDeps;
    address refundRecipient;
}

struct L2TransactionRequestTwoBridgesOuter {
    uint256 chainId;
    uint256 mintValue;
    uint256 l2Value;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    address refundRecipient;
    address secondBridgeAddress;
    uint256 secondBridgeValue;
    bytes secondBridgeCalldata;
}

struct L2TransactionRequestTwoBridgesInner {
    bytes32 magicValue;
    address l2Contract;
    bytes l2Calldata;
    bytes[] factoryDeps;
    bytes32 txDataHash;
}

struct BridgehubMintSTMAssetData {
    uint256 chainId;
    bytes stmData;
    bytes chainData;
}

struct BridgehubBurnSTMAssetData {
    uint256 chainId;
    bytes stmData;
    bytes chainData;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IBridgehub is IL1AssetHandler {
    /// @notice pendingAdmin is changed
    /// @dev Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    /// @notice Admin changed
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    /// @notice STM asset registered
    event AssetRegistered(
        bytes32 indexed assetInfo,
        address indexed _assetAddress,
        bytes32 indexed additionalData,
        address sender
    );

    event SettlementLayerRegistered(uint256 indexed chainId, bool indexed isWhitelisted);

    /// @notice Emitted when the bridging to the chain is started.
    /// @param chainId Chain ID of the hyperchain
    /// @param assetId Asset ID of the token for the hyperchain's STM
    /// @param settlementLayerChainId The chain id of the settlement layer the chain migrates to.
    event MigrationStarted(uint256 indexed chainId, bytes32 indexed assetId, uint256 indexed settlementLayerChainId);

    /// @notice Emitted when the bridging to the chain is complete.
    /// @param chainId Chain ID of the hyperchain
    /// @param assetId Asset ID of the token for the hyperchain's STM
    /// @param hyperchain The address of the hyperchain on the chain where it is migrated to.
    event MigrationFinalized(uint256 indexed chainId, bytes32 indexed assetId, address indexed hyperchain);

    /// @notice Starts the transfer of admin rights. Only the current admin or owner can propose a new pending one.
    /// @notice New admin can accept admin rights by calling `acceptAdmin` function.
    /// @param _newPendingAdmin Address of the new admin
    function setPendingAdmin(address _newPendingAdmin) external;

    /// @notice Accepts transfer of admin rights. Only pending admin can accept the role.
    function acceptAdmin() external;

    /// Getters
    function stateTransitionManagerIsRegistered(address _stateTransitionManager) external view returns (bool);

    function stateTransitionManager(uint256 _chainId) external view returns (address);

    function assetIdIsRegistered(bytes32 _baseTokenAssetId) external view returns (bool);

    function baseToken(uint256 _chainId) external view returns (address);

    function baseTokenAssetId(uint256 _chainId) external view returns (bytes32);

    function sharedBridge() external view returns (IL1AssetRouter);

    function messageRoot() external view returns (IMessageRoot);

    function getHyperchain(uint256 _chainId) external view returns (address);

    function getAllHyperchains() external view returns (address[] memory);

    function getAllHyperchainChainIDs() external view returns (uint256[] memory);

    function migrationPaused() external view returns (bool);

    function admin() external view returns (address);

    /// Mailbox forwarder

    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view returns (bool);

    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view returns (bool);

    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view returns (bool);

    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);

    //// Registry

    function createNewChain(
        uint256 _chainId,
        address _stateTransitionManager,
        bytes32 _baseTokenAssetId,
        uint256 _salt,
        address _admin,
        bytes calldata _initData,
        bytes[] calldata _factoryDeps
    ) external returns (uint256 chainId);

    function addStateTransitionManager(address _stateTransitionManager) external;

    function removeStateTransitionManager(address _stateTransitionManager) external;

    function addTokenAssetId(bytes32 _baseTokenAssetId) external;

    function setAddresses(
        address _sharedBridge,
        ISTMDeploymentTracker _stmDeployer,
        IMessageRoot _messageRoot
    ) external;

    event NewChain(uint256 indexed chainId, address stateTransitionManager, address indexed chainGovernance);

    event StateTransitionManagerAdded(address indexed stateTransitionManager);

    event StateTransitionManagerRemoved(address indexed stateTransitionManager);

    event BaseTokenAssetIdRegistered(bytes32 indexed assetId);

    function whitelistedSettlementLayers(uint256 _chainId) external view returns (bool);

    function registerSettlementLayer(uint256 _newSettlementLayerChainId, bool _isWhitelisted) external;

    // function finalizeMigrationToGateway(
    //     uint256 _chainId,
    //     address _baseToken,
    //     address _sharedBridge,
    //     address _admin,
    //     uint256 _expectedProtocolVersion,
    //     HyperchainCommitment calldata _commitment,
    //     bytes calldata _diamondCut
    // ) external;

    function forwardTransactionOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external;

    function stmAssetIdFromChainId(uint256 _chainId) external view returns (bytes32);

    function stmAssetId(address _stmAddress) external view returns (bytes32);

    function stmDeployer() external view returns (ISTMDeploymentTracker);

    function stmAssetIdToAddress(bytes32 _assetInfo) external view returns (address);

    function setAssetHandlerAddress(bytes32 _additionalData, address _assetAddress) external;

    function L1_CHAIN_ID() external view returns (uint256);

    function setLegacyBaseTokenAssetId(uint256 _chainId) external;

    function registerAlreadyDeployedHyperchain(uint256 _chainId, address _hyperchain) external;
}
