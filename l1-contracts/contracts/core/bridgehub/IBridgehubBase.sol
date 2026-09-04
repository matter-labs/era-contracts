// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {TokenBridgingData, TxStatus} from "../../common/Messaging.sol";
import {ICTMDeploymentTracker} from "../ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";

struct BridgehubMintCTMAssetData {
    uint256 chainId;
    TokenBridgingData baseTokenBridgingData;
    uint256 batchNumber;
    bytes ctmData;
    bytes chainData;
    uint256 migrationNumber;
}

struct BridgehubBurnCTMAssetData {
    uint256 chainId;
    bytes ctmData;
    bytes chainData;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IBridgehubBase {
    /// @notice Authorized L1 priority-transaction entry point.
    function interopCenter() external view returns (address);

    event InteropCenterSet(address indexed interopCenter);

    /// @notice pendingAdmin is changed
    /// @dev Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    /// @notice Admin changed
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    /// @notice CTM asset registered
    event AssetRegistered(
        bytes32 indexed assetInfo,
        address indexed _assetAddress,
        bytes32 indexed additionalData,
        address sender
    );

    event SettlementLayerRegistered(uint256 indexed chainId, bool isWhitelisted);

    event NewChain(uint256 indexed chainId, address chainTypeManager, address indexed chainGovernance);

    event ChainTypeManagerAdded(address indexed chainTypeManager);

    event ChainTypeManagerRemoved(address indexed chainTypeManager);

    event BaseTokenAssetIdRegistered(bytes32 indexed assetId);

    /// @notice Starts the transfer of admin rights. Only the current admin or owner can propose a new pending one.
    /// @notice New admin can accept admin rights by calling `acceptAdmin` function.
    /// @param _newPendingAdmin Address of the new admin
    function setPendingAdmin(address _newPendingAdmin) external;

    /// @notice Accepts transfer of admin rights. Only pending admin can accept the role.
    function acceptAdmin() external;

    /// Getters
    function chainTypeManagerIsRegistered(address _chainTypeManager) external view returns (bool);

    function chainTypeManager(uint256 _chainId) external view returns (address);

    function assetIdIsRegistered(bytes32 _baseTokenAssetId) external view returns (bool);

    function baseToken(uint256 _chainId) external view returns (address);

    function baseTokenAssetId(uint256 _chainId) external view returns (bytes32);

    function messageRoot() external view returns (IMessageRootBase);

    function getZKChain(uint256 _chainId) external view returns (address);

    function getAllZKChains() external view returns (address[] memory);

    function getAllZKChainChainIDs() external view returns (uint256[] memory);

    function admin() external view returns (address);

    function assetRouter() external view returns (IAssetRouterBase);

    function chainRegistrationSender() external view returns (address);

    function whitelistedSettlementLayers(uint256 _chainId) external view returns (bool);

    function settlementLayer(uint256 _chainId) external view returns (uint256);

    function ctmAssetIdFromChainId(uint256 _chainId) external view returns (bytes32);

    function ctmAssetIdFromAddress(address _ctmAddress) external view returns (bytes32);

    function l1CtmDeployer() external view returns (ICTMDeploymentTracker);

    function ctmAssetIdToAddress(bytes32 _assetInfo) external view returns (address);

    function chainAssetHandler() external view returns (address);

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256);

    /// Registry
    function addChainTypeManager(address _chainTypeManager) external;

    function removeChainTypeManager(address _chainTypeManager) external;

    function addTokenAssetId(bytes32 _baseTokenAssetId) external;

    function setCTMAssetAddress(bytes32 _additionalData, address _assetAddress) external;

    /// Asset Handler functions
    function forwardedBridgeBurnSetSettlementLayer(
        uint256 _chainId,
        uint256 _newSettlementLayerChainId
    ) external returns (address zkChain, address ctm);

    function forwardedBridgeMint(
        bytes32 _assetId,
        uint256 _chainId,
        TokenBridgingData calldata _baseTokenBridgingData
    ) external returns (address zkChain, address ctm);

    function registerNewZKChain(uint256 _chainId, address _zkChain, bool _checkMaxNumberOfZKChains) external;

    function forwardedBridgeConfirmTransferResult(
        uint256 _chainId,
        TxStatus _txStatus
    ) external returns (address zkChain, address ctm);
}
